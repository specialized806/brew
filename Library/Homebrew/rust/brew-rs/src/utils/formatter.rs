use crate::utils::tty;
use std::io::{self, IsTerminal};

#[allow(unused)]
pub enum Color {
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    Default,
}

pub fn ohai(string: &str) {
    let title = if io::stdout().is_terminal() {
        tty::truncate(string)
    } else {
        string
    };
    println!("{}", headline(title, Color::Blue));
}

fn arrow(string: &str, color: Color) -> String {
    prefix("==>", string, color)
}

fn headline(string: &str, color: Color) -> String {
    arrow(
        format!(
            "{bold}{string}{reset}",
            bold = tty::bold(),
            reset = tty::reset(),
        )
        .as_str(),
        color,
    )
}

fn prefix(prefix: &str, string: &str, color: Color) -> String {
    let tty_color = match color {
        Color::Red => tty::red(),
        Color::Green => tty::green(),
        Color::Yellow => tty::yellow(),
        Color::Blue => tty::blue(),
        Color::Magenta => tty::magenta(),
        Color::Cyan => tty::cyan(),
        Color::Default => tty::default(),
    };

    if prefix.is_empty() {
        return format!(
            "{color}{string}{reset}",
            color = tty_color,
            reset = tty::reset()
        );
    }

    format!(
        "{color}{prefix}{reset} {string}",
        color = tty_color,
        reset = tty::reset()
    )
}
