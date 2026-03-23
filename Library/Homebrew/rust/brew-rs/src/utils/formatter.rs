use crate::utils::tty::{self, AnsiBuilder};
use std::io::{self, IsTerminal};

pub fn ohai(string: &str) {
    let title = if io::stdout().is_terminal() {
        tty::truncate(string)
    } else {
        string
    };
    println!("{}", headline(title, &tty::blue()));
}

pub fn warning(string: &str) {
    eprintln!(
        "{warning}Warning{reset}: {string}",
        warning = AnsiBuilder::new().yellow().underline(),
        reset = tty::reset(),
    );
}

pub fn error(string: &str) {
    eprintln!(
        "{error}Error{reset}: {string}",
        error = tty::red(),
        reset = tty::reset(),
    );
}

fn arrow(string: &str, escape_sequence: &AnsiBuilder) -> String {
    prefix("==>", string, escape_sequence)
}

fn headline(string: &str, escape_sequence: &AnsiBuilder) -> String {
    arrow(
        format!(
            "{bold}{string}{reset}",
            bold = tty::bold(),
            reset = tty::reset(),
        )
        .as_str(),
        escape_sequence,
    )
}

fn prefix(prefix: &str, string: &str, escape_sequence: &AnsiBuilder) -> String {
    if prefix.trim().is_empty() {
        return format!("{escape_sequence}{string}{reset}", reset = tty::reset());
    }

    format!(
        "{escape_sequence}{prefix}{reset} {string}",
        reset = tty::reset()
    )
}
