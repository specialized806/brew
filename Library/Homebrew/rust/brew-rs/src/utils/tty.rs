use crate::homebrew;
use std::fmt;
use std::io::{self, IsTerminal};
use std::process::Command;
use std::str;
use std::sync::OnceLock;

// Color codes
const RED: &str = "31";
const GREEN: &str = "32";
const YELLOW: &str = "33";
const BLUE: &str = "34";
const MAGENTA: &str = "35";
const CYAN: &str = "36";
const DEFAULT: &str = "39";

// Style codes
const RESET: &str = "0";
const BOLD: &str = "1";
const ITALIC: &str = "3";
const UNDERLINE: &str = "4";
const STRIKETHROUGH: &str = "9";
const NO_UNDERLINE: &str = "24";

// Special codes
const UP: &str = "1A";
const DOWN: &str = "1B";
const RIGHT: &str = "1C";
const LEFT: &str = "1D";
const ERASE_LINE: &str = "K";
const ERASE_CHAR: &str = "P";

const MOVE_CURSOR_BEGINNING: &str = "0G";
const CLEAR_TO_END: &str = "K";
const HIDE_CURSOR: &str = "?25l";
const SHOW_CURSOR: &str = "?25h";

static TTY_SIZE: OnceLock<Option<TtySize>> = OnceLock::new();
#[allow(unused)]
static TTY_HEIGHT: OnceLock<usize> = OnceLock::new();
static TTY_WIDTH: OnceLock<usize> = OnceLock::new();

pub struct AnsiBuilder {
    escape_sequences: Vec<&'static str>,
}

#[derive(Clone, Copy)]
pub struct TtySize {
    pub width: usize,
    pub height: usize,
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
                #[allow(unused)]
                pub fn $name(mut self) -> Self {
                    self.escape_sequences.push($value);
                    self
                }
            )*
        }

        $(
            #[inline]
            #[allow(unused)]
            pub fn $name() -> String {
                AnsiBuilder::new().$name().to_string()
            }
        )*
    };
}

macro_rules! ansi_special_functions {
    ($( $name:ident => $value:expr ),* $(,)?) => {
        $(
            #[inline]
            #[allow(unused)]
            pub fn $name() -> String {
                if io::stdout().is_terminal() {
                    format!("\x1B[{}", $value)
                } else {
                    "".to_string()
                }
            }
        )*
    };
}

ansi_methods_and_functions! {
    red => RED,
    green => GREEN,
    yellow => YELLOW,
    blue => BLUE,
    magenta => MAGENTA,
    cyan => CYAN,
    default => DEFAULT,
    reset => RESET,
    bold => BOLD,
    italic => ITALIC,
    underline => UNDERLINE,
    strikethrough => STRIKETHROUGH,
    no_underline => NO_UNDERLINE,
}

ansi_special_functions! {
    up => UP,
    down => DOWN,
    right => RIGHT,
    left => LEFT,
    erase_line => ERASE_LINE,
    erase_char => ERASE_CHAR,
    move_cursor_beginning => MOVE_CURSOR_BEGINNING,
    clear_to_end => CLEAR_TO_END,
    hide_cursor => HIDE_CURSOR,
    show_cursor => SHOW_CURSOR,
}

#[allow(unused)]
pub fn move_cursor_up(line_count: usize) -> String {
    format!("\x1B[{line_count}A")
}

#[allow(unused)]
pub fn move_cursor_up_beginning(line_count: usize) -> String {
    format!("\x1B[{line_count}F")
}

#[allow(unused)]
pub fn move_cursor_down(line_count: usize) -> String {
    format!("\x1B[{line_count}B")
}

pub fn size() -> Option<TtySize> {
    *TTY_SIZE.get_or_init(|| {
        let command = Command::new("/bin/stty").arg("size").output().ok()?;
        let mut output = command.stdout.split(|ch| ch.is_ascii_whitespace());

        let height = str::from_utf8(output.next()?).ok()?.parse().ok()?;
        let width = str::from_utf8(output.next()?).ok()?.parse().ok()?;

        Some(TtySize { height, width })
    })
}

#[allow(unused)]
pub fn height() -> usize {
    *TTY_HEIGHT.get_or_init(|| {
        if let Some(size) = size() {
            return size.height;
        }

        if let Ok(output) = Command::new("/usr/bin/tput").arg("lines").output()
            && let Some(res) = str::from_utf8(&output.stdout)
                .ok()
                .and_then(|string| string.parse().ok())
        {
            return res;
        }

        40
    })
}

pub fn width() -> usize {
    *TTY_WIDTH.get_or_init(|| {
        if let Some(size) = size() {
            return size.width;
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
