# Combine (vendored)

Apple's Combine framework has no Android implementation, but SwiftUI's declarations are written
against it: `ObservableObject`, `@Published`, `PassthroughSubject`, publishers, cancellables.

This directory is **OpenCombine** (https://github.com/OpenCombine/OpenCombine, MIT — see
`LICENSE.txt`), pinned at commit `1c6f02c7ed8140c0ba7a783aaddb6e0685a0037b` and compiled under the
module name `Combine` so Apple's declarations resolve against it unchanged.

The only source transformation is mechanical: the library qualifies itself as `OpenCombine.`, and
each such qualifier is rewritten to `Combine.` (`scripts/port/build-vendored-combine.sh` performs
the same rewrite into `build/vendor/combine-src/`; this copy is the checked-in result so the
package builds without network access).

Its C helper layer (`__UnfairLock`, `__nextCombineIdentifier`, `__stopInDebugger`) lives in
`Sources/COpenCombineHelpers` and is implemented with pthreads, because Android has no
`os_unfair_lock`.
