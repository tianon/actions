# TODO verify outputs: too
#
# TODO this script?  separate script?  validate `env:`  (Docker actions should have any "-" containing input explicitly and composite actions should list *all* inputs explicitly)
#   - probably separate script since that applies to actions that don't have an upstream too

(
	$upstream
	| fromyaml
	| .inputs
) as $upstream

# parse comments like:
#   # lfs: not yet implemented -- ...
# into an object we can test/verify against
| gsub("(?xm)
	^
	(?<indent> \\s* )
	\\#
	\\s+
	(?<key> \\S+ )
	:
	\\s+
	not \\s+ (?: yet \\s+ )? (?: implemented | supported )
	\\s+
	--
	[^\\n]+ # enforce that it must have an explanatory comment in order to be valid
	$
"; "\(.indent)\(.key): { not: implemented }")

# parse comments like:
#   default: false # upstream default: true -- ...
# into being the upstream default instead so we ignore them for comparison
| gsub("(?xm)
	(:? \\S+ )
	\\s+
	\\#
	\\s+
	upstream \\s+ default:
	\\s+
	(?<value> \\S+ )
	\\s+
	--
	[^\\n]+ # enforce that it must have an explanatory comment in order to be valid
	$
"; "\(.value)")

| fromyaml
| .inputs

| ($upstream | keys) as $keysUp
| keys as $keys

| ($keysUp - $keys) as $missing
| ($keys - $keysUp) as $extra
| if $missing != [] then
	error("missing upstream keys: \($missing)")
end
| if $extra != [] then
	error("extra keys vs upstream: \($extra)")
end

| [
	to_entries[]
	| .key as $key
	| .value
	| $upstream[$key] as $up

	| if .not == "implemented" then
		empty
	else
		if .default != $up.default then
			"upstream default for \($key) differs: \($up.default) vs \(.default)"
		else empty end,

		empty
	end
]
| if . != [] then
	error(.)
else empty end
