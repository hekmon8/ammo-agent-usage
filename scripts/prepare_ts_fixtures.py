#!/usr/bin/env python3
"""Compile every canonical golden fixture against the TypeScript wire DTO."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
fixtures = [json.loads(p.read_text()) for p in sorted((root / 'contracts/fixtures').glob('*.json'))]
output = root / '.build/fixtures.generated.ts'
output.parent.mkdir(exist_ok=True)
output.write_text("import type { Snapshot } from '../contracts/Contracts';\nconst fixtures: Snapshot[] = " + json.dumps(fixtures, ensure_ascii=False) + ";\nvoid fixtures;\n")
print(f'Prepared {len(fixtures)} canonical fixtures for TypeScript type checking')
