// Multiple custom effects handled together
effect Logger {
    fn log(msg: Str) -> Unit
}

effect Metrics {
    fn count(name: Str) -> Unit
    fn gauge(name: Str, val: Int) -> Unit
}

fn process(x: Int) -> Int {
    Logger.log("processing")
    Metrics.count("process_calls")
    let result = x * 2
    Metrics.gauge("result", result)
    Logger.log("done")
    result
}

fn main() {
    let mut log_count = 0
    let mut metric_count = 0
    let mut last_gauge = 0

    let result = handle {
        process(21)
    } with {
        Logger.log(msg) => { log_count = log_count + 1 },
        Metrics.count(name) => { metric_count = metric_count + 1 },
        Metrics.gauge(name, val) => { last_gauge = val },
    }

    assert(result == 42, "process result")
    assert(log_count == 2, "log called twice")
    assert(metric_count == 1, "count called once")
    assert(last_gauge == 42, "gauge recorded")
    print("effect_custom_multi_effect: all tests passed")
}
