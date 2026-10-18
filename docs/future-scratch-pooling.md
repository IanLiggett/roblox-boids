# Future WorkerCore scratch pooling

Deferred from the scheduler-overloading feature. The current implementation allocates mutable scratch per job and preserves one active job per Actor.

A future optimization may lease complete scratch bundles from a pool local to the WorkerCore execution environment. Initial capacity should match expected simultaneous jobs in that environment, rather than total Actor count. If all bundles are leased, allocate another and grow capacity to meet demand. Do not block work or share a bundle already leased to another invocation.

Each invocation exclusively owns its cell arrays, bucket records, and active-record bookkeeping until its last scratch access. Return the bundle on both success and failure, reset logical counts/references before reuse, and ensure returned result buffers never alias reusable scratch. A timeout alone cannot reclaim a bundle from an invocation still using it.

Validate overlapping jobs, nested/yielding fixture execution, failures, returned-buffer independence, retained memory, allocation/GC cost, and end-to-end frame latency before restoring caching. Allowing multiple active jobs per Actor remains a separate ownership and execution-lifetime decision.
