use portable_pty::PtySize;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TerminalGeometry {
    pub cols: u16,
    pub rows: u16,
    pub cell_width_pixels: u32,
    pub cell_height_pixels: u32,
}

pub fn validate_grid(cols: u16, rows: u16) -> Result<(), String> {
    if cols == 0 || rows == 0 {
        return Err("terminal dimensions must be nonzero".into());
    }
    if cols > 4096 || rows > 4096 || u32::from(cols) * u32::from(rows) > 1024 * 1024 {
        return Err("terminal dimensions exceed the grid limit".into());
    }
    Ok(())
}

impl TerminalGeometry {
    pub fn pty_size(self) -> Result<PtySize, String> {
        validate_grid(self.cols, self.rows)?;
        let pixels = |cell: u32, count: u16| {
            cell.checked_mul(u32::from(count))
                .and_then(|value| u16::try_from(value).ok())
                .filter(|value| *value > 0)
                .ok_or_else(|| "terminal pixel dimensions exceed the kernel winsize range".to_string())
        };
        Ok(PtySize {
            cols: self.cols, rows: self.rows,
            pixel_width: pixels(self.cell_width_pixels, self.cols)?,
            pixel_height: pixels(self.cell_height_pixels, self.rows)?,
        })
    }

    #[cfg(feature = "terminal-snapshots")]
    pub fn runtime(self) -> craft_vt::Geometry {
        craft_vt::Geometry { cols: self.cols, rows: self.rows,
            cell_width: self.cell_width_pixels, cell_height: self.cell_height_pixels }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn grid_and_pixels_must_fit_both_parser_and_kernel() {
        let geometry = TerminalGeometry { cols: 80, rows: 24, cell_width_pixels: 9, cell_height_pixels: 18 };
        let size = geometry.pty_size().unwrap();
        assert_eq!((size.cols, size.rows, size.pixel_width, size.pixel_height), (80, 24, 720, 432));
        for invalid in [
            TerminalGeometry { cols: 0, ..geometry },
            TerminalGeometry { rows: 4097, ..geometry },
            TerminalGeometry { cols: 4096, rows: 4096, ..geometry },
            TerminalGeometry { cell_width_pixels: 0, ..geometry },
            TerminalGeometry { cell_height_pixels: 2731, ..geometry },
            TerminalGeometry { cell_width_pixels: u32::MAX, ..geometry },
        ] {
            assert!(invalid.pty_size().is_err());
        }
        let boundary = TerminalGeometry { cols: 1, rows: 1, cell_width_pixels: 65535, cell_height_pixels: 65535 };
        assert_eq!(boundary.pty_size().unwrap().pixel_width, 65535);
    }
}
