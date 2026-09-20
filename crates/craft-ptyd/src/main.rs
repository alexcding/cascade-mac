fn main() {
    let mut args = std::env::args_os().skip(1);
    let Some(directory) = args.next() else {
        eprintln!("usage: craft-ptyd <data-directory>");
        std::process::exit(2);
    };
    if args.next().is_some() {
        eprintln!("usage: craft-ptyd <data-directory>");
        std::process::exit(2);
    }
    // Foundation.Process may launch us as a process-group leader. Such a process
    // cannot setsid(); fork once before any threads are started and let its child
    // become the detached session leader. A normal CLI launch needs no fork.
    if unsafe { libc::getpgrp() == libc::getpid() && libc::getsid(0) != libc::getpid() } {
        match unsafe { libc::fork() } {
            -1 => { eprintln!("fork: {}", std::io::Error::last_os_error()); std::process::exit(1); }
            0 => {}
            _ => std::process::exit(0),
        }
    }
    if unsafe { libc::getsid(0) != libc::getpid() && libc::setsid() == -1 } {
        eprintln!("setsid: {}", std::io::Error::last_os_error());
        std::process::exit(1);
    }
    craft_ptyd::main(directory.into());
}
