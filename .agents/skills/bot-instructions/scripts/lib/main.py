"""Entry point behind the `bot-instructions` wrapper."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lib.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
