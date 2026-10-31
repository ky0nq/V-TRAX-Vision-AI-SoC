# ============================================================
# cov_holes.awk : urg modinfo.txt -> uncovered items only (holes.txt)
#   awk -f scripts/cov_holes.awk coverage_report/modinfo.txt > coverage_report/holes.txt
#   (make report runs this automatically)
#
#   per module (module definition sections; instance sections are skipped) :
#     line   : source lines with uncovered statements (n/m with n < m)
#     cond   : expression + its "Not Covered" rows
#     toggle : ports / signals that did not toggle both ways
#     fsm    : uncovered states / transitions
#     branch : branch construct line + its "Not Covered" rows
# ============================================================
function hdr() {
	if (!((mod, sec) in printed)) {
		printed[mod, sec] = 1
		if (sec == "line") print ""
		print "#### " mod " : " sec
	}
}

/^Module : /          { mod = $3; inmod = (mod != "uvm_pkg"); sec = ""; next }
/^Module Instance : / { inmod = 0; next }
!inmod                { next }

/^Line Coverage for Module/   { sec = "line";   next }
/^Cond Coverage for Module/   { sec = "cond";   next }
/^Toggle Coverage for Module/ { sec = "toggle"; next }
/^FSM Coverage for Module/    { sec = "fsm";    next }
/^Branch Coverage for Module/ { sec = "branch"; next }
/^Assert Coverage for Module/ { sec = "";       next }
/^-------------------/        { next }

sec == "line" && /^[0-9]+ +[0-9]+\/[0-9]+/ {
	split($2, nm, "/")
	if (nm[1] + 0 < nm[2] + 0) { hdr(); print "  " $0 }
	next
}

sec == "cond" {
	if ($1 == "LINE")                                  { cl = $2; next }
	if ($1 == "EXPRESSION" || $1 == "SUB-EXPRESSION")  { ce = $0; sub(/^ +/, "", ce); next }
	if (/Not Covered/) {
		hdr()
		if (lastc != cl ce) { print "  L" cl " : " ce; lastc = cl ce }
		print "      " $0
	}
	next
}

sec == "toggle" && NF >= 4 && ($2 == "No" || $3 == "No" || $4 == "No") {
	hdr(); print "  " $0; next
}

sec == "fsm" {
	if (/^Summary for FSM ::/) { fsm = $4; next }
	if (/Not Covered/ && !/Not included/) {
		hdr()
		if (lastf != fsm) { print "  FSM " fsm; lastf = fsm }
		print "      " $0
	}
	next
}

sec == "branch" {
	if (/^[0-9]+ {3,}[^ ]/) { bl = $0; next }
	if (/Not Covered/) {
		hdr()
		if (lastb != bl) { print "  " bl; lastb = bl }
		print "      " $0
	}
	next
}
