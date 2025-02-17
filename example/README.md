# Example - Hello, World

See full code in [/example/hello_world](https://github.com/d-markey/squadron_builder/tree/main/example/hello_world).

The classic `Hello, World!` example code with a `HelloWorld` service:

```dart
@UseLogger(ParentSquadronLogger)
@SquadronService(web: false)
class HelloWorld {
  @SquadronMethod()
  Future<String> hello([String? name]) async {
    name = name?.trim() ?? '';
    return name.isEmpty
        ? 'Hello, World! from $workerId'
        : 'Hello, $name! from $workerId';
  }
}
```

Generate code for `HelloWorldWorker` and `HelloWorldWorkerPool` with `dart run build_runner build`.

Now you're ready to go:

```dart
  Squadron.info('main() running in $workerId');
  final names = [null, 'Mary', 'John', 'Joe', 'Rick', 'Bill', 'Henry'];
  final worker = HelloWorldWorker();
  for (var name in names) {
    Squadron.info(await worker.hello(name));
  }
  worker.stop();
```

Sample output:

```
[2023-08-22T23:00:45.385735Z] [INFO] [HELLO_WORLD] main() running in HELLO_WORLD (Isolate 698145007)
[2023-08-22T23:00:45.421540Z] [CONFIG] [HELLO_WORLD] created Isolate #HELLO_WORLD.1
[2023-08-22T23:00:45.425444Z] [CONFIG] [HELLO_WORLD] connected to Isolate #HELLO_WORLD.1
[2023-08-22T23:00:45.441911Z] [INFO] [HELLO_WORLD] Hello, World! from HELLO_WORLD.1 (Isolate 30688730)
[2023-08-22T23:00:45.441911Z] [INFO] [HELLO_WORLD] Hello, Mary! from HELLO_WORLD.1 (Isolate 30688730)
[2023-08-22T23:00:45.441911Z] [INFO] [HELLO_WORLD] Hello, John! from HELLO_WORLD.1 (Isolate 30688730)
[2023-08-22T23:00:45.441911Z] [INFO] [HELLO_WORLD] Hello, Joe! from HELLO_WORLD.1 (Isolate 30688730)
[2023-08-22T23:00:45.441911Z] [INFO] [HELLO_WORLD] Hello, Rick! from HELLO_WORLD.1 (Isolate 30688730)
[2023-08-22T23:00:45.441911Z] [INFO] [HELLO_WORLD] Hello, Bill! from HELLO_WORLD.1 (Isolate 30688730)
[2023-08-22T23:00:45.441911Z] [INFO] [HELLO_WORLD] Hello, Henry! from HELLO_WORLD.1 (Isolate 30688730)
[2023-08-22T23:00:45.451444Z] [CONFIG] [HELLO_WORLD.1] terminating Isolate
```

# Example - Fibonacci sequence

See full code in [/example/fibonacci](https://github.com/d-markey/squadron_builder/tree/main/example/fibonacci).

The example computes Fibonacci numbers recursively, simply applying the definition of the Fibonacci sequence. It is very inefficient, but illustrates the effect of multithreading.

```dart
@SquadronService()
class FibService {
  @SquadronMethod()
  Future<int> fibonacci(int i) async => _fib(i);

  // naive & inefficient implementation of the Fibonacci sequence
  static int _fib(int i) => (i < 2) ? i : (_fib(i - 2) + _fib(i - 1));
}
```

To have `squadron_builder` generate the code for the worker and the worker pool, run:

```
dart run build_runner build
```

The main program runs the same computations:
* first with a plain instance of `FibService` (single-threaded, running in the main program's Isolate),
* then with an instance of `FibServiceWorker` (single-threaded, running in a dedicated Isolate),
* finally with an instance of `FibServiceWorkerPool` (multi-threaded, running in specific Isolates managed by the worker pool).

The worker and worker pool generated by `squadron_builder` both wrap the original service and implement it: as a result, they are interchangeable with the original service.

```dart
  // compute 9 fibonnaci numbers (starting from 37)
  int count = 9, start = 37;

  print('''

Computing with FibService (single-threaded, main Isolate)
  The main Isolate is busy computing the numbers.
  The timer won't trigger.
''');
  final service = FibService();
  await computeWith(service, start, count);

  print('''

Computing with FibServiceWorker (single-threaded, 1 dedicated Isolate)
  The main Isolate is available while the worker Isolate is computing numbers.
  The computation time should be roughly the same as with FibService.
  The timer triggers periodically.
''');
  final worker = FibServiceWorker();
  await worker.start();
  await computeWith(worker, start, count);
  print('  * Stats for worker ${worker.workerId}: ${worker.stats.dump()}');
  worker.stop();

  final maxWorkers = count ~/ 2;

  print('''

Computing with FibServiceWorkerPool (multi-threaded, $maxWorkers dedicated Isolate)
  The main Isolate is available while worker pool Isolates are computing numbers.
  The computation time should be significantly less compared to FibService and FibServiceWorker.
  The timer triggers periodically.
''');
  final concurrency = ConcurrencySettings(minWorkers: 1, maxWorkers: maxWorkers, maxParallel: 1);
  final pool = FibServiceWorkerPool(concurrencySettings: concurrency);
  await pool.start();
  await computeWith(pool, start, count);
  print(pool.fullStats.map((s) => '  * Stats for pool worker ${s.id}: ${s.dump()}').join('\n'));
  pool.stop();
```

Sample output:

```
  tick #1...
Timer started

Computing with FibService (single-threaded, main Isolate)
  The main Isolate is busy computing the numbers.
  The timer won't trigger.

  * Results = [24157817, 39088169, 63245986, 102334155, 165580141, 267914296, 433494437, 701408733, 1134903170]
  * Total elapsed time: 0:00:15.213226

Computing with FibServiceWorker (single-threaded, dedicated Isolate)
  The main Isolate is available while the worker Isolate is computing numbers.
  The computation time should be roughly the same as with FibService.
  The timer triggers periodically.

  tick #16 - skipped 15 ticks!
  tick #17...
  tick #18...
  tick #19...
  tick #20...
  tick #21...
  tick #22...
  tick #23...
  tick #24...
  tick #25...
  tick #26...
  tick #27...
  tick #28...
  tick #29...
  tick #30...
  tick #31...
  * Results = [24157817, 39088169, 63245986, 102334155, 165580141, 267914296, 433494437, 701408733, 1134903170]
  * Total elapsed time: 0:00:15.299236
  * Stats for worker FIB.1: totalWorkload=9 (max 9) - upTime=0:00:15.292464 - idleTime=0:00:00.000000 - status=IDLE

Computing with FibServiceWorkerPool (multi-threaded, 4 dedicated Isolate)
  The main Isolate is available while worker pool Isolates are computing numbers.
  The computation time should be significantly less compared to FibService and FibServiceWorker.
  The timer triggers periodically.

  tick #32...
  tick #33...
  tick #34...
  tick #35...
  tick #36...
  tick #37...
  tick #38...
  tick #39...
  * Results = [24157817, 39088169, 63245986, 102334155, 165580141, 267914296, 433494437, 701408733, 1134903170]
  * Total elapsed time: 0:00:08.057544
  * Stats for pool worker FIB.2: totalWorkload=3 (max 1) - upTime=0:00:08.062694 - idleTime=0:00:00.000000 - status=IDLE
  * Stats for pool worker FIB.5: totalWorkload=2 (max 1) - upTime=0:00:08.051062 - idleTime=0:00:06.077964 - status=IDLE
  * Stats for pool worker FIB.4: totalWorkload=2 (max 1) - upTime=0:00:08.051062 - idleTime=0:00:05.017407 - status=IDLE
  * Stats for pool worker FIB.3: totalWorkload=2 (max 1) - upTime=0:00:08.051062 - idleTime=0:00:03.161544 - status=IDLE

  tick #40...
Timer stopped
```

# Example - Performance benchmark

See full code in [/example/perf](https://github.com/d-markey/squadron_builder/tree/main/example/perf).

Sample summary output:

```
==== SUMMARY ====

MAX TIMER DELAY (resolution = 0:00:00.020000 aka 50.0 frames/sec)
    * main thread: 0:00:05.081533 (resolution x 254.08) - max skipped = 254
    * worker: 0:00:00.056210 (resolution x 2.81) - max skipped = 2
    * worker pool: 0:00:00.126533 (resolution x 6.33) - max skipped = 5

MAIN THREAD (baseline): executed in the main event loop.
    * Fib :  0:00:05.619219 - skipped 97.52 % (275 / 282, max = 69) - max delay = 0:00:01.403367
    * Echo:  0:00:00.566552 - skipped 89.66 % (26 / 29, max = 26) - max delay = 0:00:00.534657
    * Perf:  0:00:05.116553 - skipped 98.83 % (254 / 257, max = 254) - max delay = 0:00:05.081533

SINGLE WORKERS vs MAIN THREAD: worker counters should be slightly worse because
of serialization/deserialization. The main advantage in this scenario is to
free the main event loop and avoid skipping frames, eg in user-facing apps to
avoid glitches in the UI.
    * Fib :  0:00:05.711924 (1.65 %) - skipped 0.00 % (0 / 286, max = 0) - max delay = 0:00:00.040161 (-97.14 %)
    * Echo:  0:00:00.608711 (7.44 %) - skipped 3.23 % (1 / 31, max = 1) - max delay = 0:00:00.032436 (-93.93 %)
    * Perf:  0:00:05.365830 (4.87 %) - skipped 1.86 % (5 / 269, max = 2) - max delay = 0:00:00.056210 (-98.89 %)

WORKER POOL vs MAIN THREAD: worker pool counters should be much better even
considering the overhead of serialization/deserialization and worker scheduling.
Perf improvement depends on method execution time: the heavier the workload,
the more performance will be improved.
    * Fib :  0:00:02.543199 (-54.74 %) - skipped 0.78 % (1 / 128, max = 1) - max delay = 0:00:00.032507 (-97.68 %)
    * Echo:  0:00:00.194108 (-65.74 %) - skipped 10.00 % (1 / 10, max = 1) - max delay = 0:00:00.035975 (-93.27 %)
    * Perf:  0:00:01.511884 (-70.45 %) - skipped 15.79 % (12 / 76, max = 5) - max delay = 0:00:00.126533 (-97.51 %)
```
