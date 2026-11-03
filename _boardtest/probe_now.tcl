proc p {s} { puts "PROBE $s" }
if {[catch {open_hw_manager} e]} { p "OPEN_HW_MANAGER_FAIL $e"; exit 2 }
if {[catch {connect_hw_server -url localhost:3121} e]} { p "CONNECT_FAIL $e"; exit 2 }
p "SERVER_OK"
set tgts {}
if {[catch {set tgts [get_hw_targets]} e]} { p "NO_TARGETS $e" }
p "TARGETS=$tgts"
set found 0
foreach t $tgts {
  if {[catch {current_hw_target $t} e]} { p "TARGET_ERR $t $e"; continue }
  if {[catch {open_hw_target} e]} { p "OPEN_FAIL $t $e"; continue }
  set devs {}
  catch {set devs [get_hw_devices]}
  p "TARGET $t DEVICES=$devs"
  foreach d $devs {
    set found 1
    p "  DEV $d PART=[get_property PART $d] IDCODE=[get_property IDCODE $d]"
    foreach prop {REGISTER.CONFIG_STATUS PROGRAM.FILE REGISTER.CONFIG_STATUS.DONE} {
      if {[catch {p "    $prop=[get_property $prop $d]"} e]} { p "    $prop=<n/a>" }
    }
  }
  catch {close_hw_target}
}
p "FOUND=$found"
disconnect_hw_server
exit 0
