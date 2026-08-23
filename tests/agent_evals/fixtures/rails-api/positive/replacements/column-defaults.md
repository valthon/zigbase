# Column defaults

Rails applied these on write; ZigBase fields carry no generic default, so a
before-create hook supplies the same value. Imported rows already carry theirs.
