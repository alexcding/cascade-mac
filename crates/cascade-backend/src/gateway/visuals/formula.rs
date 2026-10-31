//! Synara `packages/shared/src/inlineVisualFormula.ts`: the arithmetic of a calculator block's
//! outputs. Agent text, so no eval: a small recursive-descent parser over numbers, input ids,
//! `+ - * / % ^`, parentheses and a fixed set of functions. The gateway only needs to know a
//! formula compiles (the page evaluates it with Synara's own module), so `compile` parses and
//! reports the first error in Synara's words, and builds nothing to evaluate.

use std::collections::HashSet;

/// Synara `FUNCTIONS`: each function's arity.
const FUNCTIONS: [(&str, usize, usize); 7] =
    [("min", 1, 16), ("max", 1, 16), ("round", 1, 2), ("floor", 1, 1), ("ceil", 1, 1), ("abs", 1, 1), ("sqrt", 1, 1)];

/// Synara `tokenize`: numbers, names and single symbols, whitespace between them skipped.
fn tokenize(source: &str) -> Result<Vec<String>, String> {
    let chars: Vec<char> = source.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        while i < chars.len() && chars[i].is_whitespace() {
            i += 1;
        }
        if i >= chars.len() {
            break;
        }
        let start = i;
        let c = chars[i];
        if c.is_ascii_digit() || (c == '.' && chars.get(i + 1).is_some_and(char::is_ascii_digit)) {
            // \d+(?:\.\d+)? | \.\d+
            if c == '.' {
                i += 1;
                while i < chars.len() && chars[i].is_ascii_digit() {
                    i += 1;
                }
            } else {
                while i < chars.len() && chars[i].is_ascii_digit() {
                    i += 1;
                }
                if chars.get(i) == Some(&'.') && chars.get(i + 1).is_some_and(char::is_ascii_digit) {
                    i += 1;
                    while i < chars.len() && chars[i].is_ascii_digit() {
                        i += 1;
                    }
                }
            }
        } else if c.is_ascii_alphabetic() || c == '_' {
            while i < chars.len() && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                i += 1;
            }
        } else {
            if !"+-*/%^(),".contains(c) {
                return Err(format!("unexpected \"{c}\""));
            }
            i += 1;
        }
        tokens.push(chars[start..i].iter().collect());
    }
    Ok(tokens)
}

struct Parser<'a> {
    tokens: Vec<String>,
    position: usize,
    variables: &'a HashSet<String>,
}

impl Parser<'_> {
    fn peek(&self) -> Option<&str> {
        self.tokens.get(self.position).map(String::as_str)
    }

    fn expect(&mut self, token: &str) -> Result<(), String> {
        if self.peek() != Some(token) {
            return Err(format!("expected \"{token}\""));
        }
        self.position += 1;
        Ok(())
    }

    fn additive(&mut self) -> Result<(), String> {
        self.multiplicative()?;
        while matches!(self.peek(), Some("+" | "-")) {
            self.position += 1;
            self.multiplicative()?;
        }
        Ok(())
    }

    fn multiplicative(&mut self) -> Result<(), String> {
        self.unary()?;
        while matches!(self.peek(), Some("*" | "/" | "%")) {
            self.position += 1;
            self.unary()?;
        }
        Ok(())
    }

    fn unary(&mut self) -> Result<(), String> {
        if matches!(self.peek(), Some("-" | "+")) {
            self.position += 1;
            return self.unary();
        }
        self.power()
    }

    fn power(&mut self) -> Result<(), String> {
        self.primary()?;
        if self.peek() == Some("^") {
            self.position += 1;
            self.unary()?;
        }
        Ok(())
    }

    fn primary(&mut self) -> Result<(), String> {
        let Some(token) = self.tokens.get(self.position).cloned() else {
            return Err("formula ends early".into());
        };
        self.position += 1;
        if token == "(" {
            self.additive()?;
            return self.expect(")");
        }
        let first = token.chars().next().unwrap_or(' ');
        if first.is_ascii_digit() || first == '.' {
            return Ok(());
        }
        if first.is_ascii_alphabetic() || first == '_' {
            if self.peek() == Some("(") {
                let Some(&(_, minimum, maximum)) = FUNCTIONS.iter().find(|(name, ..)| *name == token) else {
                    return Err(format!("unknown function \"{token}\""));
                };
                self.position += 1;
                let mut count = 0;
                if self.peek() != Some(")") {
                    self.additive()?;
                    count += 1;
                    while self.peek() == Some(",") {
                        self.position += 1;
                        self.additive()?;
                        count += 1;
                    }
                }
                self.expect(")")?;
                if count < minimum || count > maximum {
                    let count = if minimum == maximum { minimum.to_string() } else { format!("{minimum} to {maximum}") };
                    let plural = if count == "1" { "" } else { "s" };
                    return Err(format!("{token} takes {count} value{plural}"));
                }
                return Ok(());
            }
            if !self.variables.contains(&token) {
                return Err(format!("unknown input \"{token}\""));
            }
            return Ok(());
        }
        Err(format!("unexpected \"{token}\""))
    }
}

/// Synara `compileInlineVisualFormula`: whether `source` parses over `variables`, or why not.
pub fn compile(source: &str, variables: &HashSet<String>) -> Result<(), String> {
    let tokens = tokenize(source)?;
    let mut parser = Parser { tokens, position: 0, variables };
    parser.additive()?;
    if let Some(token) = parser.peek() {
        return Err(format!("unexpected \"{token}\""));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vars(names: &[&str]) -> HashSet<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn formulas_compile_or_say_why_not() {
        let v = vars(&["total", "people", "rate"]);
        for ok in ["total / people", "-total + 2 ^ -1", "round(total * rate, 2)", "max(1, 2, people) % 3", ".5 + 1.25", "(total)  "] {
            assert_eq!(compile(ok, &v), Ok(()), "{ok}");
        }
        for (bad, error) in [
            ("total / guests", "unknown input \"guests\""),
            ("eval(total)", "unknown function \"eval\""),
            ("total +", "formula ends early"),
            ("(total", "expected \")\""),
            ("total total", "unexpected \"total\""),
            ("total $ 2", "unexpected \"$\""),
            ("sqrt(1, 2)", "sqrt takes 1 value"),
            ("round()", "round takes 1 to 2 values"),
        ] {
            assert_eq!(compile(bad, &v), Err(error.to_owned()), "{bad}");
        }
    }
}
