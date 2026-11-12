#include "calc.h"

#include <QRegularExpression>
#include <cmath>

namespace {

// A small recursive-descent parser over the expression text. Each rule
// returns false on anything unexpected, so a half-typed or prose line never
// produces a number.
class Parser {
public:
    explicit Parser(const QString &text) : m_text(text) {}

    std::optional<double> parse() {
        double value = 0;
        if (!expression(value))
            return std::nullopt;
        skipSpaces();
        if (m_pos != m_text.size() || !std::isfinite(value))
            return std::nullopt;
        return value;
    }

    int binaryOperators() const { return m_binaryOperators; }

private:
    bool expression(double &value) {
        if (!term(value))
            return false;
        for (;;) {
            skipSpaces();
            const QChar op = peek();
            if (op != u'+' && op != u'-')
                return true;
            ++m_pos;
            double right = 0;
            if (!term(right))
                return false;
            ++m_binaryOperators;
            value = op == u'+' ? value + right : value - right;
        }
    }

    bool term(double &value) {
        if (!unary(value))
            return false;
        for (;;) {
            skipSpaces();
            const QChar op = peek();
            const bool multiply = op == u'*' || op == u'x' || op == u'X' || op == QChar(0x00D7);
            const bool divide = op == u'/' || op == QChar(0x00F7);
            if (!multiply && !divide)
                return true;
            ++m_pos;
            double right = 0;
            if (!unary(right))
                return false;
            ++m_binaryOperators;
            if (divide) {
                if (right == 0)
                    return false;
                value /= right;
            } else {
                value *= right;
            }
        }
    }

    bool unary(double &value) {
        skipSpaces();
        if (peek() == u'-' || peek() == u'+') {
            const bool negate = peek() == u'-';
            ++m_pos;
            if (!unary(value))
                return false;
            if (negate)
                value = -value;
            return true;
        }
        return power(value);
    }

    bool power(double &value) {
        if (!postfix(value))
            return false;
        skipSpaces();
        if (peek() != u'^')
            return true;
        ++m_pos;
        double exponent = 0;
        // Right-associative, and binds tighter than a leading minus on the
        // base but not on the exponent: 2^-1 is a half.
        if (!unary(exponent))
            return false;
        ++m_binaryOperators;
        value = std::pow(value, exponent);
        return std::isfinite(value);
    }

    bool postfix(double &value) {
        if (!primary(value))
            return false;
        skipSpaces();
        while (peek() == u'%') {
            ++m_pos;
            value /= 100;
            skipSpaces();
        }
        return true;
    }

    bool primary(double &value) {
        skipSpaces();
        if (peek() == u'(') {
            ++m_pos;
            if (!expression(value))
                return false;
            skipSpaces();
            if (peek() != u')')
                return false;
            ++m_pos;
            return true;
        }
        return number(value);
    }

    bool number(double &value) {
        static const QRegularExpression pattern(
            QStringLiteral("\\G(?:\\d{1,3}(?:,\\d{3})+|\\d+)?(?:\\.\\d+)?"));
        const QRegularExpressionMatch match = pattern.match(m_text, m_pos);
        if (!match.hasMatch() || match.capturedLength() == 0)
            return false;
        QString digits = match.captured();
        digits.remove(u',');
        bool ok = false;
        value = digits.toDouble(&ok);
        m_pos += match.capturedLength();
        return ok;
    }

    void skipSpaces() {
        while (m_pos < m_text.size() && m_text.at(m_pos).isSpace())
            ++m_pos;
    }

    QChar peek() const { return m_pos < m_text.size() ? m_text.at(m_pos) : QChar(); }

    const QString &m_text;
    qsizetype m_pos = 0;
    int m_binaryOperators = 0;
};

bool isExpressionChar(QChar c) {
    return c.isDigit() || c.isSpace() || QStringLiteral(".,+-*/^%()xX").contains(c)
        || c == QChar(0x00D7) || c == QChar(0x00F7);
}

}

namespace Calc {

std::optional<double> evaluate(const QString &expression) {
    Parser parser(expression);
    const std::optional<double> value = parser.parse();
    if (!value || parser.binaryOperators() == 0)
        return std::nullopt;
    return value;
}

QString answerFor(const QString &lineBeforeEquals) {
    // List bullets, numbered items, quotes and headings come before the sum,
    // and "- 5 + 3 =" is a bullet, not minus five.
    static const QRegularExpression markdownPrefix(
        QStringLiteral("^\\s*(?:>\\s*)*(?:#{1,6}\\s+|[-*+]\\s+(?:\\[[ xX]\\]\\s+)?|\\d+[.)]\\s+)?"));
    QString line = lineBeforeEquals;
    line.remove(0, markdownPrefix.match(line).capturedLength());

    // The calculation is the run of expression characters right before the
    // equals sign, so "Rent 1200 + 300 =" adds up just the numbers.
    qsizetype start = line.size();
    while (start > 0 && isExpressionChar(line.at(start - 1)))
        --start;
    QString expression = line.mid(start).trimmed();

    // What the backwards scan swept up from the prose before it: the x of
    // "box", a dash used as punctuation, a stray closing bracket.
    static const QRegularExpression leadingJunk(
        QStringLiteral("^(?:[xX*/^%),.\\x{00D7}\\x{00F7}]|[-+](?=\\s))[\\s]*"));
    for (;;) {
        const QRegularExpressionMatch junk = leadingJunk.match(expression);
        if (!junk.hasMatch() || junk.capturedLength() == 0)
            break;
        expression.remove(0, junk.capturedLength());
    }

    if (expression.isEmpty() || !expression.contains(QRegularExpression(QStringLiteral("\\d"))))
        return QString();

    const std::optional<double> value = evaluate(expression);
    return value ? format(*value) : QString();
}

QString format(double value) {
    if (value == 0)
        return QStringLiteral("0");
    const double magnitude = std::fabs(value);
    if (magnitude >= 1e15 || magnitude < 1e-9)
        return QString::number(value, 'g', 12);
    if (std::fabs(value - std::round(value)) < 1e-9 * std::max(1.0, magnitude))
        return QString::number(static_cast<long long>(std::llround(value)));

    QString text = QString::number(value, 'f', 10);
    while (text.endsWith(u'0'))
        text.chop(1);
    if (text.endsWith(u'.'))
        text.chop(1);
    return text;
}

}
