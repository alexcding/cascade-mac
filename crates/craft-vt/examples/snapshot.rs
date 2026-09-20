//! Fixture generator for native-surface integration tests. VT input on stdin,
//! binary snapshot on stdout; no shell execution or application data access.
use std::io::{Read, Write};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.len() != 2 && args.len() != 4 {
        return Err("usage: snapshot <columns> <rows> [cell-width-pixels cell-height-pixels]".into());
    }
    let mut terminal = craft_vt::Terminal::new(args[0].parse()?, args[1].parse()?)?;
    if args.len() == 4 {
        terminal.resize_geometry(craft_vt::Geometry {
            cols: args[0].parse()?, rows: args[1].parse()?,
            cell_width: args[2].parse()?, cell_height: args[3].parse()?,
        })?;
    }
    let mut input = Vec::new();
    std::io::stdin()
        .take(craft_vt::SNAPSHOT_LIMIT as u64 + 1)
        .read_to_end(&mut input)?;
    if input.len() > craft_vt::SNAPSHOT_LIMIT {
        return Err("fixture input exceeds limit".into());
    }
    terminal.feed(&input);
    std::io::stdout().write_all(&terminal.snapshot()?)?;
    Ok(())
}
