# Source this to let an external Python talk to a running DaVinci Resolve Studio (macOS).
export RESOLVE_SCRIPT_API="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
export RESOLVE_SCRIPT_LIB="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"
export PYTHONPATH="$RESOLVE_SCRIPT_API/Modules/:$PYTHONPATH"
