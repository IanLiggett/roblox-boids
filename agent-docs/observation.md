# Observer maintenance contracts

Observer camera modes

Current interface

- Observation.Camera implements Free, Boid, Group, and Overview. Free flight uses WASD, Q/E world elevation, RMB look, Shift acceleration, and adjustable speed. Boid/group/overview orbit use world-Y up, clamped pitch, and wheel/button zoom.
- Boid follow targets the renderer's current pose. Group follow samples only the selected group's rendered bounds at 2 Hz and smooths the centroid each frame. Overview samples scenario definitions, never live boid populations.
- The developer controls expose mode buttons, boid-ID selection, group cycling by runtime ID, speed, and zoom. Text focus, the Roblox menu, and window blur suppress flight/look input. Stop removes the camera context, driver, and input listeners before handoff restoration.
- Deletion clears the corresponding selection and enters free flight without repositioning the camera. Missing/first-render/stale states remain explicit; camera modes never place or turn boids.

Observer presentation cost

Current implementation

- The feature sampler and obstacle capture continue independently of dock visibility. Hidden inspector, camera, and session pages defer widget formatting until their existing page becomes visible; world overlays remain active. Visibility listeners are disconnected during presentation cleanup.
- Public inspection/sample/obstacle getters still return independent nested values. The private inspection sample retains the immutable accepted server sample and obtains obstacle copies only when returning a public snapshot, avoiding intermediate diagnostic copies.
- Captured obstacle geometry occupies the leading pooled adornment/label slots. Its private cache uses boid ID, capture generation, job order, and layer settings; selection/group visuals follow those slots. Exit/Stop clears the cache and pools. Unchanged frozen geometry is retained while decision-age wording and moving selection visuals continue updating.
- Stationary camera/input properties are assigned only when different. Camera replacement, the first driver frame, focus-mode changes, and explicit view moves still apply the held view/focus through Handoff.

Boids initial replay requests

Current implementation

- SimulationReplication.Bootstrap derives identity from the remote Player and bounds public initial-state reads per connection. Requests during a replay or after its successful reliable completion do no serialization work. Failed sends allow at most three attempts with a five-second cooldown; disconnected Players are rejected and PlayerRemoving clears state.
- This is one-shot bootstrap admission, not gameplay authorization or arbitrary full resynchronization. Begin/Complete are informational markers and never reset live client groups.

Scenario observation remotes

Current implementation

- Shared Scenarios.ObservationTypes declares the existing command variants and session fields. Trusted client construction and validated server handlers use them; the request boundary accepts unknown and validates raw fields before typed dispatch. A shared type is not authorization or a schema validator.
- BoidsReplicated.Scenarios.ObservationRequest accepts developer session commands only. Server.Scenarios.Observation derives identity from Player; caller-supplied viewer IDs have no authority. Studio players, the individual experience creator, and server-only ObservationConfig.allowedUserIds are authorized. Group ownership alone grants no player access.
- Mutations require the caller's active session token. Fixed observers are owned by that session, limited to four, and require finite Vector3 positions. The token bucket allows 10 requests/second with a burst capacity of 20. Closing one's own session bypasses the bucket so exit remains possible after a burst or permission revocation.
- Authorization is checked on requests and the 4 Hz diagnostic loop. Ordinary players receive no active session or diagnostic stream. Benchmark-prefixed scenarios are unavailable even for authorized developers.
- Active observation sessions acquire the server/client host hooks supplied at startup. The host owns its authoritative input and local controls; exit/disconnect/Stop/access revocation release returned cleanup and every session-owned streaming focus. No host controls are discovered by name inside the package.
- Observer buttons are non-modal. Handoff owns mouse unlocking during active sessions; hidden UI must not override the host's mouse lock during initialization or after exit.
- ObservationState is server-to-owning-client accepted configuration with monotonic revisions. ObservationSample is a separate diagnostic-only channel; session/selection identity and timestamp ordering prevent delayed samples replacing newer inspection data. Neither channel grants boid movement authority or feeds snapshot reconciliation. Diagnostic payloads now include group/cell/path-node/tick metadata and selected-only simulation age from GetBoidObservation. sampledAt remains read/transport time; it is never substituted for simulation-update time. Getter copies include the nested state record, so inspector callers cannot mutate the cached diagnostic sample.
