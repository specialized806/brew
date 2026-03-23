use crate::homebrew;
use std::fmt;
use std::io::{self, IsTerminal};
use std::process::Command;
use std::str;
use std::sync::OnceLock;

// Color codes
const RED: &str = "31";
const YELLOW: &str = "33";
const BLUE: &str = "34";

// Style codes
const RESET: &str = "0";
const BOLD: &str = "1";
const UNDERLINE: &str = "4";

static TTY_WIDTH: OnceLock<usize> = OnceLock::new();

pub struct AnsiBuilder {
    escape_sequences: Vec<&'static str>,
}

fn colorful_output() -> bool {
    if homebrew::brew_no_color() {
        return false;
    }
    if homebrew::brew_color() {
        return true;
    }
    io::stdout().is_terminal()
}

impl fmt::Display for AnsiBuilder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if colorful_output() {
            write!(f, "\x1B[{}m", self.escape_sequences.join(";"))
        } else {
            write!(f, "")
        }
    }
}

impl AnsiBuilder {
    pub fn new() -> Self {
        AnsiBuilder {
            escape_sequences: Vec::new(),
        }
    }
}

macro_rules! ansi_methods_and_functions {
    ($( $name:ident => $value:expr ),* $(,)?) => {
        impl AnsiBuilder {
            $(
                #[inline]
                pub fn $name(mut self) -> Self {
                    self.escape_sequences.push($value);
                    self
                }
            )*
        }

        $(
            #[inline]
            #[allow(unused)]
            pub fn $name() -> AnsiBuilder {
                AnsiBuilder::new().$name()
            }
        )*
    };
}

ansi_methods_and_functions! {
    red => RED,
    yellow => YELLOW,
    blue => BLUE,
    reset => RESET,
    bold => BOLD,
    underline => UNDERLINE,
}

pub fn width() -> usize {
    *TTY_WIDTH.get_or_init(|| {
        if let Ok(command) = Command::new("/bin/stty").arg("size").output() {
            let mut output = command.stdout.split(|ch| ch.is_ascii_whitespace());

            let _ = output.next();
            if let Some(width) = output
                .next()
                .and_then(|string| str::from_utf8(string).ok())
                .and_then(|string| string.parse().ok())
            {
                return width;
            }
        }

        if let Ok(output) = Command::new("/usr/bin/tput").arg("cols").output()
            && let Some(res) = str::from_utf8(&output.stdout)
                .ok()
                .and_then(|string| string.parse().ok())
        {
            return res;
        }

        80
    })
}

pub fn truncate(string: &str) -> &str {
    let w = width();

    if w < 4 {
        return string;
    }

    let mut end = usize::min(string.len(), w - 4);

    while end > 0 && !string.is_char_boundary(end) {
        end -= 1;
    }

    &string[..end]
}
