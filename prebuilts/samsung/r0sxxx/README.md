r0sxxx — ARM32 audio client for the r9s WFD stack
=================================================

What this is
------------
Three stock libraries, and nothing else. This is not a general donor.

    system/lib/libaudioclient.so
    system/lib/libnblog.so
    system/lib/android.media.audio.common.types-V4-cpp.so

The r0sxxx audio client has 35 DT_NEEDED entries. 33 of them are already
present in the Android 17 system image; these three are the whole gap, and
they are the complete closure of what has to be added:

  * `libaudioclient.so` is the replacement itself, not a dependency of it.
  * `libnblog.so` and `android.media.audio.common.types-V4-cpp.so` are the
    only two of its dependencies that the target does not ship.

The r9s WFD port links against the 16-argument
`android::AudioTrack::AudioTrack` constructor that Android 17 dropped in
favour of an overload taking one extra trailing
`std::__1::basic_string ... const&`, and r0sxxx still exports the old one.

Why r0sxxx and not z3sxxx
--------------------------
These libraries were taken from the *system* partition, and the system
partition in that tree identifies itself as r0sxxx:

    ro.product.system.name=r0sxxx
    ro.product.system.device=essi
    ro.product.system.model=SM-G988B

The same tree's *vendor* partition identifies as z3sxxx. Only product and
system came from the S22 side of that port work dir, so the system libs are
r0sxxx libs and the donor is named after the partition they were read from.
Do not "correct" this to z3sxxx based on the vendor props; the vendor is not
where these files came from.

Provenance
----------
Source tree:
/mnt/caddy/coisas_do_miguel/Port/QuantumROM/FW/SM-S901B

Note that the directory name says SM-S901B while the props say SM-G988B.
This is a port work dir assembled from more than one device: vendor and odm
from the S20 Ultra, product and system from the S22. The build id still
reads S901BXXUMHZCB. Trust the props of the partition over the directory
name.

Not stock Samsung, and not necessarily reproducible. The tree is a work dir
of an unrelated in-progress port, not a clean factory image. The libraries
themselves are untouched Samsung binaries, but there is no factory package
to re-extract from if they are ever lost.

Re-extracting
-------------
If these have to come out of that tree again, or out of a different r0sxxx
build, re-check all three of these before trusting the result:

1. The donor exports the exact symbol the WFD stack needs. Match the whole
   symbol, not a substring: the Android 17 library exports the old name with
   an extra trailing parameter, so a substring match accepts it and silently
   passes a donor that is the wrong one.

       readelf --dyn-syms -W system/lib/libaudioclient.so | \
           awk '{ print $NF }' | \
           grep -qxF "$WFD_AUDIO_TRACK_SYMBOL"

   Must print the symbol exactly once. This is what the build asserts, so a
   bad re-extract fails at build time rather than at boot. A value of 2 means
   the donor is already Android 17 and carries both overloads, which means
   the port problem is elsewhere.

2. Only those two dependencies are still missing from the target. If a future
   re-extract needs a fourth library, the gap is bigger than this donor
   claims and the README is stale:

       readelf -d system/lib/libaudioclient.so | grep NEEDED

   Checked against the device, the count of NEEDED entries with no counterpart
   in /system/lib, /system/lib64 or the media apex must be exactly 2.

3. The symbol is unversioned. There is no Verneed/Verdef to satisfy, so the
   bare symbol name is the whole contract. A donor that introduces symbol
   versioning needs a different fix.

Known risk
----------
The target system has `android.media.audio.common.types-V5-cpp.so`. This
donor pulls V4 of that library into the remotedisplay process, so V4 and V5
of the same media audio types end up loaded in one process. remotedisplay
starts and stays up with this combination, so it is not immediately fatal,
but it is untested against a real DeX session. If audio init inside a
session ever faults, this mismatch is the first thing to look at.

Scope
-----
This donor is loaded only by the remotedisplay/WFD service, via
`LD_LIBRARY_PATH=/system/lib/wfd` set in remotedisplay.rc. It does not
replace the system-wide audio client, so no other process sees these
libraries.
