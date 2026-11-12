#pragma once

#include <QString>
#include <optional>

// Inline arithmetic for lines like "1200 + 340 =". Typing the equals sign at
// the end of such a line fills in the answer, the way Notes on the Mac does.
namespace Calc {

// Evaluates a plain arithmetic expression: + - * / ^, x × ÷ as multiply and
// divide, a trailing % as hundredths, parentheses, and 1,000-style thousands.
// Returns nothing for anything that is not a complete expression.
std::optional<double> evaluate(const QString &expression);

// Given the text of a line up to (not including) a just-typed "=", returns
// the formatted answer, or an empty string when the line does not end in a
// calculation. A lone number ("5 =") is not a calculation.
QString answerFor(const QString &lineBeforeEquals);

// "48", "0.5", "3.3333333333": no exponent for everyday sizes, no trailing
// zeros.
QString format(double value);

}
