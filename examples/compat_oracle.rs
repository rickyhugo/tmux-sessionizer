use std::{sync::Arc, time::Instant};

use nucleo::{
    pattern::{CaseMatching, Normalization},
    Nucleo,
};

fn main() {
    let mut args = std::env::args().skip(1);
    assert_eq!(args.next().as_deref(), Some("rank"));
    let query = args.next().expect("query");
    let mut matcher = Nucleo::new(nucleo::Config::DEFAULT, Arc::new(|| {}), None, 1);
    let injector = matcher.injector();
    for item in args {
        injector.push(item.clone(), |_, columns| columns[0] = item.into());
    }
    drop(injector);
    matcher
        .pattern
        .reparse(0, &query, CaseMatching::Smart, Normalization::Smart, false);
    let deadline = Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let status = matcher.tick(10);
        if !status.running {
            break;
        }
        assert!(Instant::now() < deadline, "matcher did not settle");
        std::thread::yield_now();
    }
    let snapshot = matcher.snapshot();
    for item in snapshot.matched_items(..snapshot.matched_item_count()) {
        println!("{}", item.data);
    }
}
