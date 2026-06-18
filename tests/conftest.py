# Ensures `import _bin` resolves from tests/admin/ and tests/smtp/ when pytest
# collects those subdirectories. Loaded before any test module under tests/.
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
