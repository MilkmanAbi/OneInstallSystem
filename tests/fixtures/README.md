# Historical compatibility fixtures

These are unmodified source snapshots from this repository, not relabeled
copies of the current runtime. `legacy-runtimes.tsv` records the runtime
version, full Git commit, and SHA-256 of each archive. The compatibility
suite verifies the digest before extraction and the runtime's own version
before installation. Each archive includes its original LICENSE.

Regenerate with the recorded commit:

```sh
git archive --format=tar.gz --output=tests/fixtures/ois-VERSION.tar.gz COMMIT ois install.sh VERSION LICENSE
```

Do not refresh these when bumping the current OIS version. They deliberately
preserve the old implementations and store/config formats.
