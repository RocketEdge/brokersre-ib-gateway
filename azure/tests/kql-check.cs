#:package Microsoft.Azure.Kusto.Language@12.4.1
// Offline static analysis of every KQL query the Azure pack ships.
//
// Purpose   No Azure login exists where the tests run, so the queries cannot be executed.
//           Microsoft's Kusto language service parses and binds them against the table schema
//           instead: a syntax error, an unknown column or function, or an operator applied to
//           the wrong type fails here rather than at deployment or, worse, silently in an
//           alert rule (rules are deployed with skipQueryValidation).
// Usage     dotnet run kql-check.cs -- <declarations.json> <kql directory> <workbook.json>
//           declarations.json  output of drift-declarations.jq: the tables and columns of the
//                              COMPILED Bicep template, so queries are checked against what
//                              will really be deployed.
//           kql directory      every *.kql file is checked. A file named alert-*.kql must also
//                              return the string columns Instance and Condition, because the
//                              alert rules split by exactly these dimensions.
//           workbook.json      every query of the workbook is checked (tiles and drop-down
//                              parameters); the workbook tokens {Instance} and
//                              {TimeRange:grain} are replaced by literals first.
// Output    One PASS/FAIL line per query; exit code 1 when any query has an error.
// Limits    Static analysis proves a query is well-formed for this schema. It does not prove
//           that the query returns what its comment promises; that needs data in a workspace.
using System.Text.Json;
using Kusto.Language;
using Kusto.Language.Symbols;

if (args.Length != 3)
{
    Console.Error.WriteLine("usage: kql-check <declarations.json> <kql directory> <workbook.json>");
    return 2;
}

string declarationsPath = args[0];
string kqlDirectory = args[1];
string workbookPath = args[2];

GlobalState globals = BuildGlobals(declarationsPath);
int failures = 0;

foreach (string path in Directory.GetFiles(kqlDirectory, "*.kql").OrderBy(p => p, StringComparer.Ordinal))
{
    string name = Path.GetFileName(path);
    bool isAlert = name.StartsWith("alert-", StringComparison.Ordinal);
    failures += Check(name, File.ReadAllText(path), globals, requireAlertColumns: isAlert);
}

int workbookQueries = 0;
using (JsonDocument workbook = JsonDocument.Parse(File.ReadAllText(workbookPath)))
{
    foreach ((string title, string query) in WorkbookQueries(workbook.RootElement))
    {
        workbookQueries++;
        // {Instance} is a multi-select workbook parameter that expands to quoted values;
        // {TimeRange:grain} is the bin size the workbook derives from the time range.
        string runnable = query
            .Replace("{Instance}", "'*'", StringComparison.Ordinal)
            .Replace("{TimeRange:grain}", "5m", StringComparison.Ordinal);
        failures += Check($"workbook: {title}", runnable, globals, requireAlertColumns: false);
    }
}

if (workbookQueries == 0)
{
    Console.WriteLine("FAIL  workbook: no query found in the workbook file");
    failures++;
}

return failures == 0 ? 0 : 1;

/// <summary>
/// Builds the analysis context: one database holding the pack's tables with the columns of the
/// compiled Bicep template.
/// </summary>
/// <param name="path">Path of the declarations JSON ({"tables": [{"name", "columns": [{"name", "type"}]}]}).</param>
/// <returns>Globals whose default database contains the tables.</returns>
/// <exception cref="InvalidDataException">The file declares no table or an unknown column type.</exception>
static GlobalState BuildGlobals(string path)
{
    using JsonDocument declarations = JsonDocument.Parse(File.ReadAllText(path));
    List<TableSymbol> tables = [];
    foreach (JsonElement table in declarations.RootElement.GetProperty("tables").EnumerateArray())
    {
        List<ColumnSymbol> columns = [];
        foreach (JsonElement column in table.GetProperty("columns").EnumerateArray())
        {
            string columnName = column.GetProperty("name").GetString()!;
            string columnType = column.GetProperty("type").GetString()!;
            columns.Add(new ColumnSymbol(columnName, ScalarType(columnType)));
        }

        tables.Add(new TableSymbol(table.GetProperty("name").GetString()!, columns));
    }

    if (tables.Count == 0)
    {
        throw new InvalidDataException("the declarations file contains no table");
    }

    DatabaseSymbol database = new("workspace", tables);
    return GlobalState.Default.WithDatabase(database);
}

/// <summary>Maps a Log Analytics column type name to the Kusto scalar type.</summary>
/// <param name="type">Type name as the tables API spells it (case-insensitive).</param>
/// <returns>The scalar type symbol.</returns>
/// <exception cref="InvalidDataException">The type name is not one a custom table can have.</exception>
static ScalarSymbol ScalarType(string type) => type.ToLowerInvariant() switch
{
    "string" => ScalarTypes.String,
    "int" => ScalarTypes.Int,
    "long" => ScalarTypes.Long,
    "real" => ScalarTypes.Real,
    "boolean" => ScalarTypes.Bool,
    "datetime" => ScalarTypes.DateTime,
    "dynamic" => ScalarTypes.Dynamic,
    "guid" => ScalarTypes.Guid,
    _ => throw new InvalidDataException($"unknown column type '{type}'"),
};

/// <summary>
/// Parses and binds one query and prints PASS or FAIL with every error.
/// </summary>
/// <param name="name">Label printed for the query.</param>
/// <param name="query">KQL text.</param>
/// <param name="globals">Analysis context with the table schema.</param>
/// <param name="requireAlertColumns">When true the query must return string columns Instance and Condition.</param>
/// <returns>0 when the query is valid, 1 otherwise.</returns>
static int Check(string name, string query, GlobalState globals, bool requireAlertColumns)
{
    KustoCode code = KustoCode.ParseAndAnalyze(query, globals);
    List<string> problems = [];
    foreach (Diagnostic diagnostic in code.GetDiagnostics())
    {
        if (diagnostic.Severity == DiagnosticSeverity.Error)
        {
            (int line, int column) = LineAndColumn(query, diagnostic.Start);
            problems.Add($"line {line}, column {column}: {diagnostic.Message}");
        }
    }

    if (problems.Count == 0)
    {
        if (code.ResultType is not TableSymbol result)
        {
            problems.Add("the query does not return a table");
        }
        else if (requireAlertColumns)
        {
            foreach (string required in new[] { "Instance", "Condition" })
            {
                ColumnSymbol? column = result.Columns.FirstOrDefault(c => c.Name == required);
                if (column is null)
                {
                    problems.Add($"an alert query must return the column {required} (the rule splits by it)");
                }
                else if (column.Type != ScalarTypes.String)
                {
                    problems.Add($"column {required} must be a string, it is {column.Type.Name}");
                }
            }
        }
    }

    if (problems.Count == 0)
    {
        Console.WriteLine($"PASS  {name}");
        return 0;
    }

    Console.WriteLine($"FAIL  {name}");
    foreach (string problem in problems)
    {
        Console.WriteLine($"      {problem}");
    }

    return 1;
}

/// <summary>Converts a character offset into a 1-based line and column.</summary>
/// <param name="text">The query text.</param>
/// <param name="offset">Zero-based character offset reported by the language service.</param>
/// <returns>Line and column, both starting at 1.</returns>
static (int Line, int Column) LineAndColumn(string text, int offset)
{
    int line = 1;
    int column = 1;
    for (int index = 0; index < offset && index < text.Length; index++)
    {
        if (text[index] == '\n')
        {
            line++;
            column = 1;
        }
        else
        {
            column++;
        }
    }

    return (line, column);
}

/// <summary>
/// Finds every log query of an Azure workbook (items of type 3, also inside groups).
/// </summary>
/// <param name="element">Root element of the workbook JSON, or a nested group.</param>
/// <returns>Title and KQL text of each query item.</returns>
static IEnumerable<(string Title, string Query)> WorkbookQueries(JsonElement element)
{
    if (!element.TryGetProperty("items", out JsonElement items) || items.ValueKind != JsonValueKind.Array)
    {
        yield break;
    }

    foreach (JsonElement item in items.EnumerateArray())
    {
        if (!item.TryGetProperty("content", out JsonElement content) || content.ValueKind != JsonValueKind.Object)
        {
            continue;
        }

        if (content.TryGetProperty("query", out JsonElement query) && query.ValueKind == JsonValueKind.String)
        {
            string title = content.TryGetProperty("title", out JsonElement titleElement)
                ? titleElement.GetString() ?? "(untitled)"
                : item.TryGetProperty("name", out JsonElement nameElement) ? nameElement.GetString() ?? "(untitled)" : "(untitled)";
            yield return (title, query.GetString()!);
        }

        // A drop-down parameter can be filled by a query of its own.
        if (content.TryGetProperty("parameters", out JsonElement parameters) && parameters.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement parameter in parameters.EnumerateArray())
            {
                if (parameter.TryGetProperty("query", out JsonElement parameterQuery) && parameterQuery.ValueKind == JsonValueKind.String)
                {
                    string parameterName = parameter.TryGetProperty("name", out JsonElement n) ? n.GetString() ?? "?" : "?";
                    yield return ($"parameter {parameterName}", parameterQuery.GetString()!);
                }
            }
        }

        foreach ((string Title, string Query) nested in WorkbookQueries(content))
        {
            yield return nested;
        }
    }
}
