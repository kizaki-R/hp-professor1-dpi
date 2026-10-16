#![windows_subsystem = "windows"]

fn main() {
    hp_professor_1_dpi::install::prepare();
    if let Err(err) = hp_professor_1_dpi::ui::run() {
        hp_professor_1_dpi::ui::log(&err);
    }
}
