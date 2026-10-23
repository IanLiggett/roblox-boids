# Client presentation mode

- [x] Add a startup-only presentation setting; keep the current simulation mode as default and reject direct rendering with client-only scenarios.
- [x] Route snapshot packets either to correction intake or directly to the renderer; preserve reliable lifecycle handling and skip client workers in direct-render mode.
- [x] Update architecture/maintenance notes and focused checks; build the project and sourcemap.

Direct rendering continues to use the existing reliable lifecycle coordinator. Review a lifecycle-only path separately if this mode needs further CPU reduction.

Verification: Game and standalone package Rojo builds/sourcemaps plus diff check passed. Focused analysis found no errors in edited modules; it also reports existing Catalog type errors at lines 554, 555 and 568. Lune is unavailable and the Studio UnitTest suite was not run.
