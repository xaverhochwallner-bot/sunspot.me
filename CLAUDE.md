# Sunspot.me — Claude Guidelines

## Git: commit and push after every change

After completing any code change (no matter how small), always:

1. `git add` the changed files
2. `git commit -m "<short description>"`
3. `git push origin dev`

Do this automatically without asking for confirmation. Every change must be saved to the remote.
