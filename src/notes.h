#pragma once

#include <QDateTime>
#include <QObject>
#include <QString>
#include <QUrl>
#include <QVariantList>
#include <QVector>

class Backend;

// The notes library behind the sidebar. Notes live inside the app, in its
// data folder (~/.local/share/Omacom/omawrite-plus/notes): one plain Markdown
// file per note, named by an id, and index.json beside them holding each
// note's title and dates. The writer never picks a file or a folder; the
// editor's own auto-save, crash recovery and atomic writes keep each note
// safe, because to the editor a note is just the file it has open.
class Notes : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList notes READ notes NOTIFY notesChanged)
    Q_PROPERTY(QString currentId READ currentId NOTIFY currentChanged)
    Q_PROPERTY(QString currentTitle READ currentTitle NOTIFY currentChanged)

public:
    struct Note {
        QString id;
        QString title;
        QString preview;
        QDateTime created;
        QDateTime modified;
    };

    Notes(Backend *backend, const QString &directory, QObject *parent = nullptr);

    QVariantList notes() const;
    QString currentId() const { return m_currentId; }
    QString currentTitle() const;
    QString directory() const { return m_directory; }

    // Opens the most recently edited note, or a fresh one in an empty
    // library. A draft recovered after a crash stays on screen and is filed
    // as the note it came from.
    Q_INVOKABLE void start();
    Q_INVOKABLE QString createNote();
    Q_INVOKABLE void openNote(const QString &id);
    Q_INVOKABLE void deleteNote(const QString &id);
    Q_INVOKABLE void setTitle(const QString &title);
    // The ids of the notes whose title or text holds the query, any case.
    Q_INVOKABLE QStringList search(const QString &query) const;
    // What the sidebar and the window title call a note.
    Q_INVOKABLE QString displayTitle(const QString &id) const;

    // Copies a Markdown file in as a new note titled after the file; the file
    // itself is left alone. Returns the new id, or an empty string with the
    // reason in error.
    QString importFile(const QString &path, QString *error);

    QUrl urlFor(const QString &id) const;
    static QString previewOf(const QString &text);

signals:
    void notesChanged();
    void currentChanged();

private:
    void load();
    bool writeIndex();
    void noteSaved();
    void showCurrent();
    int indexOf(const QString &id) const;
    QString readText(const QString &id) const;
    bool isBlank(const QString &id) const;
    void sortByModified();

    Backend *m_backend;
    QString m_directory;
    QVector<Note> m_notes;
    QString m_currentId;
};
