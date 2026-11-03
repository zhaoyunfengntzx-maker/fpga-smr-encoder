# -----------------------------------------------------------------------------
#  _boardtest/prog_retry.tcl -- download a bitstream to SRAM with target-lock retry
#
#  Bit file comes from env var BITFILE (required) and optional TAG for log prefix.
#  The HS2 target is frequently still held by the user's Vivado GUI for a few
#  seconds; a single open_hw_target fails with
#      ERROR: [Labtoolstcl 44-494] There is no active target available ...
#  so retry with 4 s backoff instead of restarting hw_server.
#
#  Run:
#    $env:BITFILE='C:/.../enc_top_disp_v68.bit'; $env:TAG='DISP';
#    powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
#        -Tcl _boardtest\prog_retry.tcl -LogFile prog_retry.log -Tail 60
# -----------------------------------------------------------------------------
set BIT $::env(BITFILE)
set TAG $::env(TAG)
proc p {s} { global TAG; puts "$TAG $s" }
proc die {s} { global TAG; puts "$TAG FATAL: $s"; puts "$TAG DONE"; error $s }

p "BEGIN"
if {![info exists BIT] || ![file exists $BIT]} { die "bitstream missing: $BIT" }
p "  bit = $BIT ([file size $BIT] bytes, [clock format [file mtime $BIT] -format {%Y-%m-%d %H:%M:%S}])"

if {[catch {open_hw_manager} e]} { die "open_hw_manager: $e" }
if {[catch {connect_hw_server -url localhost:3121} e]} { die "connect_hw_server: $e" }

set dev ""
for {set i 1} {$i <= 8} {incr i} {
    set ok 1
    if {[catch {
        set tgts [get_hw_targets]
        if {[llength $tgts] == 0} { error "no hw_target" }
        current_hw_target [lindex $tgts 0]
        open_hw_target
        set dev [lindex [get_hw_devices] 0]
        if {$dev eq ""} { error "no device in target" }
    } e]} {
        set ok 0
        p "  attempt $i failed: $e"
        catch { close_hw_target }
        after 4000
    }
    if {$ok} { p "  attempt $i OK target=[current_hw_target] dev=$dev"; break }
}
if {$dev eq ""} { die "target still locked after retries" }

catch { p "  PART=[get_property PART $dev] IDCODE=[get_property IDCODE $dev]" }

set_property PROGRAM.FILE $BIT $dev
if {[catch {program_hw_devices $dev} e]} { catch { close_hw_target }; die "program_hw_devices: $e" }
p "  download done"

catch { refresh_hw_device -update_hw_probes false $dev }
catch { p "  DONE=[get_property REGISTER.CONFIG_STATUS.DONE $dev]" }
catch { close_hw_target }
p "PROGRAMMED_OK"
exit 0
