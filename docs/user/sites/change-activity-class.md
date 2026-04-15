# Change Activity Class

Use this item to tell `simai-env` how busy the site really is.

Available classes:

- `standard` for normal everyday use,
- `high-traffic` for busy sites that need a stronger baseline,
- `rarely-used` for sites that should keep a smaller footprint.

Choose it when:

- a site got busier after launch,
- a legacy site is mostly idle,
- the current optimization recommendation no longer matches reality.

What happens:

- the chosen class is stored in managed metadata,
- `simai-env` maps it to an internal performance mode,
- PHP-backed sites get an updated pool governance baseline.

What to expect:

- traffic keeps flowing,
- this is less drastic than `Pause site`,
- after the change you should review `Activity & optimization` again.
