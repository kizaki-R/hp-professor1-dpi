fn main() {
    match hp_professor_1_dpi::vendor::read_once() {
        Ok(text) => {
            println!("{text}");
            std::process::exit(0);
        }
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    }
}
