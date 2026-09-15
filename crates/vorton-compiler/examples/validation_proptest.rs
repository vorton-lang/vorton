use std::cell::Cell;
use std::env;
use std::fs;
use std::path::Path;
use std::process::ExitCode;

use proptest::prelude::*;
use proptest::test_runner::{Config, RngSeed, TestCaseResult, TestError, TestRunner};

const CASES: u32 = 64;
const RNG_SEED: u64 = 0x564f_5254_4f4e;
const SHRINK_LIMIT: u32 = 1_024;
const FAILURE_THRESHOLD: u8 = 10;

fn runner(cases: u32) -> TestRunner {
    TestRunner::new(Config {
        cases,
        failure_persistence: None,
        max_shrink_iters: SHRINK_LIMIT,
        rng_seed: RngSeed::Fixed(RNG_SEED),
        ..Config::default()
    })
}

fn intentional_property(value: u8) -> TestCaseResult {
    prop_assert!(
        value < FAILURE_THRESHOLD,
        "intentional Proptest counterexample"
    );
    Ok(())
}

fn positive() -> Result<(), String> {
    let generated = Cell::new(0_u32);
    runner(CASES)
        .run(&(0_u8..=100), |value| {
            generated.set(generated.get() + 1);
            prop_assert!(value <= 100);
            Ok(())
        })
        .map_err(|error| format!("positive property did not pass: {error}"))?;

    if generated.get() < CASES {
        return Err(format!(
            "positive property generated {} cases, expected at least {CASES}",
            generated.get()
        ));
    }

    println!(
        "VERDICT=POSITIVE_OK TARGET=proptest_generation GENERATED_CASES={}",
        generated.get()
    );
    Ok(())
}

fn negative(record: &Path) -> Result<(), String> {
    let generated = Cell::new(0_u32);
    let result = runner(CASES).run(&(0_u8..=100), |value| {
        generated.set(generated.get() + 1);
        intentional_property(value)
    });

    let (reason, shrunk_input) = match result {
        Err(TestError::Fail(reason, shrunk_input)) => (reason, shrunk_input),
        Err(TestError::Abort(reason)) => {
            return Err(format!(
                "intentional negative property aborted without a counterexample: {reason}"
            ));
        }
        Ok(()) => return Err("intentional negative property unexpectedly passed".to_owned()),
    };

    let contents = format!(
        "property=value_below_{FAILURE_THRESHOLD}\nrng_seed={RNG_SEED}\nshrunk_input={shrunk_input}\n"
    );
    fs::write(record, contents)
        .map_err(|error| format!("cannot write replay record {}: {error}", record.display()))?;

    println!(
        "VERDICT=EXPECTED_COUNTEREXAMPLE TARGET=proptest_shrinking GENERATED_CASES={} SHRUNK_INPUT={shrunk_input} REASON={reason}",
        generated.get()
    );
    println!("REPLAY_RECORD={}", record.display());
    Ok(())
}

fn replay(record: &Path) -> Result<(), String> {
    let contents = fs::read_to_string(record)
        .map_err(|error| format!("cannot read replay record {}: {error}", record.display()))?;
    let shrunk_input = contents
        .lines()
        .find_map(|line| line.strip_prefix("shrunk_input="))
        .ok_or_else(|| "replay record has no shrunk_input".to_owned())?
        .parse::<u8>()
        .map_err(|error| format!("replay record has invalid shrunk_input: {error}"))?;

    let result = runner(1).run(&Just(shrunk_input), intentional_property);
    match result {
        Err(TestError::Fail(_, replayed_input)) if replayed_input == shrunk_input => {
            println!(
                "VERDICT=REPLAYED_COUNTEREXAMPLE TARGET=proptest_replay REPLAY_INPUT={replayed_input}"
            );
            Ok(())
        }
        Err(TestError::Fail(_, replayed_input)) => Err(format!(
            "replay changed the counterexample from {shrunk_input} to {replayed_input}"
        )),
        Err(TestError::Abort(reason)) => {
            Err(format!("replay aborted without a counterexample: {reason}"))
        }
        Ok(()) => Err(format!(
            "recorded input {shrunk_input} no longer reproduces the failure"
        )),
    }
}

fn main() -> ExitCode {
    let mut arguments = env::args_os().skip(1);
    let Some(mode) = arguments.next() else {
        eprintln!("usage: validation_proptest <positive|negative|replay> [record]");
        return ExitCode::FAILURE;
    };
    let record = arguments.next();
    if arguments.next().is_some() {
        eprintln!("INFRASTRUCTURE_ERROR=unexpected extra argument");
        return ExitCode::FAILURE;
    }

    let result = match mode.to_str() {
        Some("positive") if record.is_none() => positive(),
        Some("negative") => record
            .as_deref()
            .ok_or_else(|| "negative mode requires a replay record path".to_owned())
            .and_then(|record| negative(Path::new(record))),
        Some("replay") => record
            .as_deref()
            .ok_or_else(|| "replay mode requires a replay record path".to_owned())
            .and_then(|record| replay(Path::new(record))),
        _ => Err("usage: validation_proptest <positive|negative|replay> [record]".to_owned()),
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("INFRASTRUCTURE_ERROR={error}");
            ExitCode::FAILURE
        }
    }
}
