// scripts/lib/args.mjs
export function parseArgs(argv, spec) {
  const flags = new Set(spec.flags ?? []);
  const values = new Set(spec.values ?? []);
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (!tok.startsWith("--")) throw new Error(`unexpected argument: ${tok}`);
    const name = tok.slice(2);
    if (flags.has(name)) {
      out[name] = true;
    } else if (values.has(name)) {
      const val = argv[++i];
      if (val === undefined) throw new Error(`missing value for --${name}`);
      out[name] = val;
    } else {
      throw new Error(`unknown option: --${name}`);
    }
  }
  return out;
}
