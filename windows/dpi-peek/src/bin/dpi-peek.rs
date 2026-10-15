#![windows_subsystem = "windows"]

fn main() {
    dpi_peek::install::prepare();
    if let Err(err) = dpi_peek::ui::run() {
        dpi_peek::ui::log(&err);
    }
}
