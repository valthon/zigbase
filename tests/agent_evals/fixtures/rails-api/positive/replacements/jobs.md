# Job disposition

`NotificationJob` becomes a scheduled job on the target. No enqueued Rails job
survives the cutover; the queue is drained before the final snapshot.
