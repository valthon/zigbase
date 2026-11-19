# Ensures `import _bin` resolves from tests/admin/ and tests/smtp/ when pytest
# collects those subdirectories. Loaded before any test module under tests/.
import sys
import pathlib
import os

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

# Every Python suite (admin, CLI, tools, SMTP, S3 and migration families) launches
# dev-mode servers with cheap password hashing. A hashing benchmark may override it.
os.environ["ZIGBASE_FAKE_HASH"] = "1"
