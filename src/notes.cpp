#include "notes.h"

#include "backend.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSaveFile>
#include <QUuid>

#include <algorithm>

namespace {

const QString indexFileName = QStringLiteral("index.json");

QString newId() {
    return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

}

Notes::Notes(Backend *backend, const QString &directory, QObject *parent)
    : QObject(parent), m_backend(backend), m_directory(directory) {
    QDir().mkpath(m_directory);
    load();
    if (m_backend)
        connect(m_backend, &Backend::saveSucceeded, this, &Notes::noteSaved);
}

QVariantList Notes::notes() const {
    QVariantList list;
    list.reserve(m_notes.size());
    for (const Note &note : m_notes) {
        list.append(QVariantMap{
            {QStringLiteral("id"), note.id},
            {QStringLiteral("title"), displayTitle(note.id)},
            {QStringLiteral("preview"), note.preview},
            {QStringLiteral("modified"), note.modified},
            {QStringLiteral("pinned"), note.pinned},
        });
    }
    return list;
}

QString Notes::currentTitle() const {
    const int index = indexOf(m_currentId);
    return index < 0 ? QString() : m_notes.at(index).title;
}

QString Notes::displayTitle(const QString &id) const {
    const int index = indexOf(id);
    if (index < 0)
        return QString();
    const Note &note = m_notes.at(index);
    if (!note.title.trimmed().isEmpty())
        return note.title.trimmed();
    return tr("New Note");
}

void Notes::start() {
    // A crash leaves its draft in the editor before we get here. If it
    // belongs to a note, carry on with that note; if it came from somewhere
    // else, file it as a new note so it is not lost.
    if (m_backend && m_backend->modified()) {
        const QFileInfo info(m_backend->fileUrl().toLocalFile());
        const QString id = info.completeBaseName();
        if (info.absolutePath() == QDir(m_directory).absolutePath() && indexOf(id) >= 0) {
            m_currentId = id;
            showCurrent();
            m_backend->save();
            return;
        }
        const QString rescued = newId();
        const QDateTime now = QDateTime::currentDateTime();
        m_notes.prepend({rescued, tr("Recovered"), QString(), now, now});
        writeIndex();
        m_currentId = rescued;
        m_backend->saveAs(urlFor(rescued));
        showCurrent();
        emit notesChanged();
        return;
    }

    if (m_notes.isEmpty()) {
        createNote();
        return;
    }
    openNote(m_notes.first().id);
}

QString Notes::createNote() {
    // Like Notes on the Mac, an untouched new note is reused rather than
    // piling up blank ones.
    if (!m_currentId.isEmpty() && isBlank(m_currentId)
        && !(m_backend && m_backend->modified())) {
        return m_currentId;
    }

    const QString id = newId();
    QSaveFile file(urlFor(id).toLocalFile());
    if (!file.open(QIODevice::WriteOnly) || !file.commit()) {
        if (m_backend)
            m_backend->showStatus(tr("Could not create a note in %1.").arg(m_directory));
        return QString();
    }

    const QDateTime now = QDateTime::currentDateTime();
    m_notes.prepend({id, QString(), QString(), now, now});
    writeIndex();
    emit notesChanged();
    openNote(id);
    return id;
}

void Notes::openNote(const QString &id) {
    if (indexOf(id) < 0)
        return;
    if (id == m_currentId && m_backend && m_backend->fileUrl() == urlFor(id))
        return;

    const QString previous = m_currentId;
    if (m_backend && m_backend->modified()) {
        m_backend->save();
        // A note that cannot be written stays open rather than being
        // dropped from the screen with its changes.
        if (m_backend->modified())
            return;
    }

    m_currentId = id;
    showCurrent();
    if (m_backend)
        m_backend->open(urlFor(id));

    // Leaving a note that never got any words or a title throws it away.
    if (!previous.isEmpty() && previous != id && isBlank(previous)) {
        QFile::remove(urlFor(previous).toLocalFile());
        m_notes.removeAt(indexOf(previous));
        writeIndex();
        emit notesChanged();
    }
}

void Notes::deleteNote(const QString &id) {
    const int index = indexOf(id);
    if (index < 0)
        return;

    if (id == m_currentId) {
        // Move the editor off the note first, so it neither saves the note
        // back nor reports its file as deleted from under it.
        if (m_backend)
            m_backend->discardRecovery();
        QString next;
        for (const Note &note : std::as_const(m_notes)) {
            if (note.id != id) {
                next = note.id;
                break;
            }
        }
        m_currentId.clear();
        if (next.isEmpty()) {
            // Clear the edits being thrown away, so the fresh note starts
            // blank and is not filed as having unsaved changes.
            if (m_backend)
                m_backend->open(urlFor(id));
            const QDateTime now = QDateTime::currentDateTime();
            const QString fresh = newId();
            QSaveFile file(urlFor(fresh).toLocalFile());
            if (file.open(QIODevice::WriteOnly))
                file.commit();
            m_notes.append({fresh, QString(), QString(), now, now});
            next = fresh;
        }
        m_currentId = next;
        showCurrent();
        if (m_backend)
            m_backend->open(urlFor(next));
    }

    QFile::remove(urlFor(id).toLocalFile());
    m_notes.removeAt(indexOf(id));
    writeIndex();
    emit notesChanged();
}

void Notes::setTitle(const QString &title) {
    const int index = indexOf(m_currentId);
    if (index < 0 || m_notes.at(index).title == title)
        return;

    Note &note = m_notes[index];
    note.title = title;
    note.modified = QDateTime::currentDateTime();
    sortByModified();
    writeIndex();
    if (m_backend)
        m_backend->setDisplayName(displayTitle(m_currentId));
    emit notesChanged();
}

void Notes::togglePinned(const QString &id) {
    const int index = indexOf(id);
    if (index < 0)
        return;
    m_notes[index].pinned = !m_notes.at(index).pinned;
    sortByModified();
    writeIndex();
    emit notesChanged();
}

bool Notes::isPinned(const QString &id) const {
    const int index = indexOf(id);
    return index >= 0 && m_notes.at(index).pinned;
}

QStringList Notes::search(const QString &query) const {
    QStringList ids;
    const QString needle = query.trimmed();
    for (const Note &note : m_notes) {
        if (needle.isEmpty() || note.title.contains(needle, Qt::CaseInsensitive)
            || readText(note.id).contains(needle, Qt::CaseInsensitive)) {
            ids.append(note.id);
        }
    }
    return ids;
}

QString Notes::importFile(const QString &path, QString *error) {
    QFile source(path);
    if (!source.open(QIODevice::ReadOnly | QIODevice::Text)) {
        if (error)
            *error = tr("Could not read %1.").arg(path);
        return QString();
    }
    const QByteArray contents = source.readAll();

    const QString id = newId();
    QSaveFile file(urlFor(id).toLocalFile());
    if (!file.open(QIODevice::WriteOnly) || file.write(contents) != contents.size()
        || !file.commit()) {
        if (error)
            *error = tr("Could not write the note into %1.").arg(m_directory);
        return QString();
    }

    const QFileInfo info(path);
    const QDateTime modified = info.lastModified();
    m_notes.append({id, info.completeBaseName(), previewOf(QString::fromUtf8(contents)),
                    modified, modified});
    sortByModified();
    writeIndex();
    emit notesChanged();
    return id;
}

QString Notes::addToJar(const QString &line) {
    QString jar;
    for (const Note &note : std::as_const(m_notes)) {
        if (note.title.trimmed().compare(QStringLiteral("Idea jar"), Qt::CaseInsensitive) == 0) {
            jar = note.id;
            break;
        }
    }
    if (jar.isEmpty()) {
        for (const Note &note : std::as_const(m_notes)) {
            if (note.pinned) {
                jar = note.id;
                break;
            }
        }
    }
    if (jar.isEmpty()) {
        jar = newId();
        QSaveFile file(urlFor(jar).toLocalFile());
        if (!file.open(QIODevice::WriteOnly) || !file.commit())
            return QString();
        const QDateTime now = QDateTime::currentDateTime();
        m_notes.prepend({jar, QStringLiteral("Idea jar"), QString(), now, now});
    }

    const QString item = QStringLiteral("- ") + line.simplified();
    if (m_backend && jar == m_currentId && m_backend->fileUrl() == urlFor(jar)) {
        // The editor holds the newest text; add to that and let it save.
        emit appendToEditor(item);
        m_backend->showStatus(tr("Added to %1").arg(displayTitle(jar)));
        return jar;
    }

    QString text = readText(jar);
    if (!text.isEmpty() && !text.endsWith(QLatin1Char('\n')))
        text += QLatin1Char('\n');
    text += item;
    QSaveFile file(urlFor(jar).toLocalFile());
    const QByteArray bytes = text.toUtf8();
    if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size() || !file.commit())
        return QString();

    Note &note = m_notes[indexOf(jar)];
    note.preview = previewOf(text);
    note.modified = QDateTime::currentDateTime();
    sortByModified();
    writeIndex();
    emit notesChanged();
    return jar;
}

QUrl Notes::urlFor(const QString &id) const {
    return QUrl::fromLocalFile(QDir(m_directory).filePath(id + QStringLiteral(".md")));
}

QString Notes::previewOf(const QString &text) {
    // The first line with words in it, without the Markdown around them.
    static const QRegularExpression markup(
        QStringLiteral("^\\s*(?:>\\s*)*(?:#{1,6}\\s+|[-*+]\\s+(?:\\[[ xX]\\]\\s+)?|\\d+[.)]\\s+)?"));
    static const QRegularExpression emphasis(QStringLiteral("[*_~`]+"));
    const QStringList lines = text.split(u'\n');
    for (const QString &raw : lines) {
        QString line = raw;
        line.remove(0, markup.match(line).capturedLength());
        line.remove(emphasis);
        line = line.simplified();
        if (!line.isEmpty())
            return line.left(120);
    }
    return QString();
}

void Notes::load() {
    m_notes.clear();
    const QDir dir(m_directory);

    QFile indexFile(dir.filePath(indexFileName));
    if (indexFile.open(QIODevice::ReadOnly)) {
        const QJsonArray entries = QJsonDocument::fromJson(indexFile.readAll())
                                       .object().value(QStringLiteral("notes")).toArray();
        for (const QJsonValue &value : entries) {
            const QJsonObject entry = value.toObject();
            const QString id = entry.value(QStringLiteral("id")).toString();
            // An entry whose file is gone has nothing left to show.
            if (id.isEmpty() || !QFileInfo::exists(urlFor(id).toLocalFile()) || indexOf(id) >= 0)
                continue;
            m_notes.append({id, entry.value(QStringLiteral("title")).toString(), QString(),
                            QDateTime::fromString(entry.value(QStringLiteral("created")).toString(),
                                                  Qt::ISODate),
                            QDateTime::fromString(entry.value(QStringLiteral("modified")).toString(),
                                                  Qt::ISODate),
                            entry.value(QStringLiteral("pinned")).toBool()});
        }
    }

    // A note file the index does not know (the index lost or older than the
    // note) still shows up, untitled, rather than vanishing.
    const QFileInfoList files = dir.entryInfoList({QStringLiteral("*.md")}, QDir::Files);
    for (const QFileInfo &info : files) {
        if (indexOf(info.completeBaseName()) < 0)
            m_notes.append({info.completeBaseName(), QString(), QString(),
                            info.birthTime().isValid() ? info.birthTime() : info.lastModified(),
                            info.lastModified()});
    }

    for (Note &note : m_notes) {
        if (!note.modified.isValid())
            note.modified = QFileInfo(urlFor(note.id).toLocalFile()).lastModified();
        if (!note.created.isValid())
            note.created = note.modified;
        note.preview = previewOf(readText(note.id));
    }
    sortByModified();
}

bool Notes::writeIndex() {
    QJsonArray entries;
    for (const Note &note : std::as_const(m_notes)) {
        entries.append(QJsonObject{
            {QStringLiteral("id"), note.id},
            {QStringLiteral("title"), note.title},
            {QStringLiteral("created"), note.created.toString(Qt::ISODateWithMs)},
            {QStringLiteral("modified"), note.modified.toString(Qt::ISODateWithMs)},
            {QStringLiteral("pinned"), note.pinned},
        });
    }
    QSaveFile file(QDir(m_directory).filePath(indexFileName));
    if (!file.open(QIODevice::WriteOnly)) {
        if (m_backend)
            m_backend->showStatus(tr("Could not save the notes list."));
        return false;
    }
    file.write(QJsonDocument(QJsonObject{{QStringLiteral("notes"), entries}}).toJson());
    if (!file.commit()) {
        if (m_backend)
            m_backend->showStatus(tr("Could not save the notes list."));
        return false;
    }
    return true;
}

void Notes::noteSaved() {
    const int index = indexOf(m_currentId);
    if (index < 0 || !m_backend || m_backend->fileUrl() != urlFor(m_currentId))
        return;

    Note &note = m_notes[index];
    note.preview = previewOf(m_backend->documentText());
    note.modified = QDateTime::currentDateTime();
    sortByModified();
    writeIndex();
    // The editor reports saves by file name; say it by the note's title.
    m_backend->showStatus(tr("Saved"));
    emit notesChanged();
}

void Notes::showCurrent() {
    if (m_backend)
        m_backend->setDisplayName(displayTitle(m_currentId));
    emit currentChanged();
}

int Notes::indexOf(const QString &id) const {
    for (int index = 0; index < m_notes.size(); ++index) {
        if (m_notes.at(index).id == id)
            return index;
    }
    return -1;
}

QString Notes::readText(const QString &id) const {
    QFile file(urlFor(id).toLocalFile());
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return QString();
    return QString::fromUtf8(file.readAll());
}

bool Notes::isBlank(const QString &id) const {
    const int index = indexOf(id);
    return index >= 0 && m_notes.at(index).title.trimmed().isEmpty()
        && readText(id).trimmed().isEmpty();
}

void Notes::sortByModified() {
    std::stable_sort(m_notes.begin(), m_notes.end(), [](const Note &a, const Note &b) {
        if (a.pinned != b.pinned)
            return a.pinned;
        return a.modified > b.modified;
    });
}
