# Schema drift check between what Vector emits and what the Bicep template declares.
#
# Input  (stdin, slurped with -s; no arguments, so the call survives any shell quoting):
#        first document: {"dcr": {"streamDeclarations": {...}, "dataFlows": [...]},
#          "tables": [<schema>...]}, cut from the COMPILED template of azure/bicep/main.bicep
#          by drift-declarations.jq;
#        every further document: one captured row,
#          {"capture": "<DCR stream name>", "row": {<column>: <value>, ...}}.
# Output one text line per problem; no output means the three declarations agree:
#          1. every key Vector emits is a declared stream column, and every declared column
#             is carried by at least one fixture row (so a column cannot be declared and never sent);
#          2. every value has the JSON type the column type requires;
#          3. each stream has a table of the same name with the same columns and types, and
#             exactly one data flow that routes the stream to that table.
# Why    The Logs Ingestion API silently drops keys the stream does not declare and writes
#        null for a value of the wrong type, so drift would show up only as missing data.
#        Vector's sink writes TimeGenerated from the event timestamp, hence the rename below.

# of_type($t): true when the value (.) is acceptable JSON for a stream column of type $t.
def of_type($t):
  if $t == "string" then type == "string"
  elif $t == "int" or $t == "long" then type == "number" and . == floor
  elif $t == "real" then type == "number"
  elif $t == "boolean" then type == "boolean"
  elif $t == "datetime" then
    type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")
  elif $t == "dynamic" then type == "object" or type == "array"
  else false
  end;

.[0] as $decl
| .[1:] as $rows
| ($decl.dcr.streamDeclarations // {}) as $streams
| [
    (if ($streams | length) == 0 then "no stream declarations found in the compiled template" else empty end),
    ( $streams | to_entries[] | . as $s
      | ($s.key | ltrimstr("Custom-")) as $table
      | ($s.value.columns | map({key: .name, value: .type}) | from_entries) as $cols
      | [ $rows[] | select(.capture == $s.key) | .row
          | with_entries(if .key == "timestamp" then .key = "TimeGenerated" else . end) ] as $rs
      | ($rs | map(keys) | add // [] | unique) as $seen
      | ([$decl.tables[] | select(.name == $table)] | first) as $t
      | (
          (if ($rs | length) == 0 then "\($s.key): no captured row" else empty end),
          (($seen - ($cols | keys))[] | "\($s.key): Vector emits \(.) but the stream does not declare it"),
          ((($cols | keys) - $seen)[] | "\($s.key): the stream declares \(.) but no captured row carries it"),
          ( $rs[] | to_entries[] | . as $kv
            | select($cols[$kv.key] != null)
            | select(($kv.value | of_type($cols[$kv.key])) | not)
            | "\($s.key): \($kv.key) = \($kv.value | tojson) is not of type \($cols[$kv.key])" ),
          ( if $t == null then "\($s.key): no table named \($table) in the template"
            elif ($t.columns | map({key: .name, value: (.type | ascii_downcase)}) | from_entries) != $cols
            then "\($s.key): the columns of table \($table) differ from the stream declaration"
            else empty
            end ),
          ( if ([$decl.dcr.dataFlows[]? | select(.streams == [$s.key] and .outputStream == $s.key)] | length) == 1
            then empty
            else "\($s.key): expected exactly one data flow from the stream to the table of the same name"
            end )
        )
    ),
    ( $rows | map(.capture) | unique | map(select($streams[.] == null))[]
      | "Vector captures stream \(.) that the data collection rule does not declare" )
  ]
| unique
| .[]
