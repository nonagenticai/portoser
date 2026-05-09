"""Side-effect-only module: silences third-party deprecation noise on import.

main.py imports this *first* so the filters are in place before pydantic /
websockets / authlib are imported and emit warnings via their own warnings
module configurations.
"""

import warnings

warnings.filterwarnings("ignore", category=DeprecationWarning, module="pydantic")
warnings.filterwarnings("ignore", category=DeprecationWarning, module="websockets")
warnings.filterwarnings("ignore", category=DeprecationWarning, module="authlib")
