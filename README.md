# intel-tigerlake-throttle-fix
Linux kernel patch for Intel i7-1185G7 (TigerLake/INTC1040) CPU   throttling. Adds enable_policy sysfs attribute to int3400_thermal   driver + RAPL/EPP tuning. Fixes 1.8→3.9 GHz sustained. No full kernel   recompile needed
