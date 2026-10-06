//! Values worked out once and kept a while, by key: a caller that comes while a value is being
//! worked out waits for that work rather than starting its own, so a burst of cold calls (the `@`
//! menu on every keystroke, two pages asking for the providers at once) costs one listing or one
//! round of probes.

use std::{
    collections::HashMap,
    future::Future,
    hash::Hash,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use tokio::sync::OnceCell;

type Slot<T> = Arc<OnceCell<(Instant, T)>>;

pub(super) struct Flights<K, T> {
    /// How long a worked-out value stands, from when its work ended.
    ttl: Duration,
    /// The most keys kept; past it the stale ones go, then all.
    max: usize,
    slots: Mutex<HashMap<K, Slot<T>>>,
}

impl<K: Eq + Hash + Clone, T: Clone> Flights<K, T> {
    pub(super) fn new(ttl: Duration, max: usize) -> Self {
        Self { ttl, max, slots: Mutex::new(HashMap::new()) }
    }

    /// `key`'s value: the one kept while it is fresh, the one being worked out while it is, else
    /// `work`'s. A caller dropped mid-work hands the work to the next one waiting.
    pub(super) async fn get<F, Fut>(&self, key: &K, work: F) -> T
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = T>,
    {
        let slot = {
            let mut slots = self.slots.lock().unwrap();
            match slots.get(key) {
                Some(slot) if self.usable(slot) => slot.clone(),
                _ => {
                    if slots.len() >= self.max {
                        slots.retain(|_, slot| self.usable(slot));
                        if slots.len() >= self.max {
                            slots.clear();
                        }
                    }
                    let slot = Slot::default();
                    slots.insert(key.clone(), slot.clone());
                    slot
                }
            }
        };
        let (_, value) = slot
            .get_or_init(|| async {
                let value = work().await;
                (Instant::now(), value)
            })
            .await;
        value.clone()
    }

    /// Being worked out, or worked out less than `ttl` ago.
    fn usable(&self, slot: &Slot<T>) -> bool {
        slot.get().is_none_or(|(at, _)| at.elapsed() < self.ttl)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    #[tokio::test]
    async fn concurrent_cold_calls_share_one_work_and_a_stale_value_is_worked_out_again() {
        let flights: Flights<&str, usize> = Flights::new(Duration::from_millis(200), 4);
        let runs = AtomicUsize::new(0);
        let work = || async {
            tokio::time::sleep(Duration::from_millis(50)).await;
            runs.fetch_add(1, Ordering::SeqCst) + 1
        };
        let (a, b, c) = tokio::join!(flights.get(&"root", work), flights.get(&"root", work), flights.get(&"root", work));
        assert_eq!((a, b, c), (1, 1, 1));
        assert_eq!(runs.load(Ordering::SeqCst), 1, "one work for three cold calls");
        assert_eq!(flights.get(&"other", work).await, 2, "another key works on its own");
        tokio::time::sleep(Duration::from_millis(250)).await;
        assert_eq!(flights.get(&"root", work).await, 3, "stale, it is worked out again");
    }

    #[tokio::test]
    async fn a_caller_dropped_mid_work_leaves_the_work_to_the_next() {
        let flights: Flights<(), u8> = Flights::new(Duration::from_secs(10), 1);
        let dropped = tokio::time::timeout(Duration::from_millis(10), flights.get(&(), || std::future::pending::<u8>())).await;
        assert!(dropped.is_err());
        assert_eq!(flights.get(&(), || async { 7 }).await, 7);
    }
}
