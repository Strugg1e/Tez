use std::io::{self, Read, Write};
use tez_backend_wire::Decoder;

fn roundtrip() -> Result<(), Box<dyn std::error::Error>> {
    let mut decoder = Decoder::new();
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let mut chunk = [0_u8; 8192];
    loop {
        let count = input.read(&mut chunk)?;
        if count == 0 {
            decoder.finish()?;
            output.flush()?;
            return Ok(());
        }
        for frame in decoder.push(&chunk[..count])? {
            output.write_all(&frame.encode()?)?;
        }
    }
}

fn main() {
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    if arguments != ["--roundtrip"] {
        eprintln!("usage: tez-backend-wire --roundtrip");
        std::process::exit(2);
    }
    if let Err(error) = roundtrip() {
        eprintln!("tez-backend-wire: {error}");
        std::process::exit(1);
    }
}
