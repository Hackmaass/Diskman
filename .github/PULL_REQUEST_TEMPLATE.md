## Summary of Changes
Provide a brief overview of the changes introduced in this PR and the reasoning behind them.

## Type of Change
- [ ] New cleanup target category (added to `src/modules/Invoke-SmartCleanup.ps1`)
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] UI / UX improvement (`src/xaml/MainWindow.xaml` or `src/app.ps1`)
- [ ] Performance enhancement or scanner optimization
- [ ] Documentation update (`README.md`, `CONTRIBUTING.md`, etc.)

## Safety & Testing Checklist
- [ ] I have tested these changes on a live Windows machine.
- [ ] Any new cleanup paths have been verified for safety and do **not** touch personal documents, OS roots, or browser credentials.
- [ ] I ran the automated test suite and all tests passed:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\test_verify.ps1
  ```
- [ ] I regenerated the standalone bundle using the compiler:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\Compile.ps1
  ```
- [ ] The standalone `release/diskman.ps1` runs without syntax errors.

## Screenshots / Verification Output (if applicable)
If you changed UI elements or added a new target, please attach a screenshot or paste output logs.
