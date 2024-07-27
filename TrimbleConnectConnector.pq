[Version = "1.0.0"]
section TrimbleConnectConnector;

//Variables
authorizationJson = Json.Document(Extension.Contents("Authorization.json"))[trimbleConnect];

authorizationUrl = authorizationJson[authorizeUrl];
tokenUri = authorizationJson[tokenUrl];
redirectUrl = authorizationJson[redirectUrl];
clientId = authorizationJson[clientId];
clientSecret = authorizationJson[clientSecret];
scope = authorizationJson[scope];

// Subqueries
GetFolderItemsQuery = Extension.LoadFunction("GetFolderItemsQuery.pqm");
GetProjectsQuery = Extension.LoadFunction("GetProjectsQuery.pqm");
FetchPage = Extension.LoadFunction("FetchPage.pqm");
GenerateByPage = Extension.LoadFunction("GenerateByPage.pqm");

StartLogin = (resourceUrl, state, display) =>
    let
        AuthorizeUrl = authorizationUrl
            & "?"
            & Uri.BuildQueryString(
                [
                    scope = scope,
                    response_type = "code",
                    redirect_uri = redirectUrl,
                    client_id = clientId,
                    client_secret = clientSecret,
                    state = state
                ]
            )
    in
        [
            LoginUri = AuthorizeUrl,
            CallbackUri = redirectUrl,
            WindowHeight = 800,
            WindowWidth = 600
        ];

FinishLogin = (c, dataSourcePath, context, callbackUri, state) =>
    let
        Parts = Uri.Parts(callbackUri)[Query]
    in
        TokenMethod(dataSourcePath, Parts[code], "authorization_code", context);

TokenMethod = (dataSourcePath, code, grant_type, optional verifier) =>
    let
        codeVerifier = if (verifier <> null) then [code_verifier = verifier] else [],
        codeParameter = if (grant_type = "authorization_code") then [code = code] else [refresh_token = code],
        query = codeVerifier
            & codeParameter
            & [
                client_id = clientId,
                client_secret = clientSecret,
                grant_type = grant_type,
                redirect_uri = redirectUrl
            ],
        ManualHandlingStatusCodes = {},
        Response = Web.Contents(
            tokenUri,
            [
                Content = Text.ToBinary(Uri.BuildQueryString(query)),
                Headers = [
                    #"Content-type" = "application/x-www-form-urlencoded",
                    #"Accept" = "application/json"
                ],
                ManualStatusHandling = ManualHandlingStatusCodes
            ]
        ),
        Parts = Json.Document(Response)
    in
        // check for error in response
        if (Parts[error]? <> null) then
            error Error.Record(Parts[error], Parts[message]?)
        else
            Parts;

Refresh = (ca, resourceUrl, oldCredentials) =>
    TokenMethod(resourceUrl, oldCredentials[refresh_token], "refresh_token");

[DataSource.Kind = "TrimbleConnectConnector", Publish = "TrimbleConnectConnector.Publish"]
shared TrimbleConnectConnector.Contents = Value.ReplaceType(ConnectorImpl, ConnectorType);

ConnectorType = type function (
    region as (
        type text meta [
            Documentation.FieldCaption = "Region",
            Documentation.AllowedValues = {
                Extension.LoadString("RegionNorthAmerica"),
                Extension.LoadString("RegionEurope"),
                Extension.LoadString("RegionAsia"),
                Extension.LoadString("RegionAustralia")
            }
        ]
    ),
    optional modelIds as (
        type text meta [
            Documentation.FieldCaption = Extension.LoadString("ModelId"),
            Documentation.FieldDescription = Extension.LoadString("SpecifyModelIds")
        ]
    )
) as table meta [
    Documentation.Name = "Trimble Connect",
    Documentation.LongDescription = "Load data from Trimble Connect models"
];

ConnectorImpl = (region as text, optional modelIds as text) =>
    let
        navTable =
            if (modelIds <> null) then
                let
                    modelList = Text.Split(modelIds, ";"),
                    modelEntities = List.Transform(modelList, each GetModelEntities(region, _)),
                    modelEntitesTable = Table.FromValue(modelEntities),
                    renamed = Table.RenameColumns(modelEntitesTable, {{"Value", "Data"}}),
                    #"Added Column" = Table.AddColumn(renamed, "ItemKind", each "Table", type text),
                    #"Added Index" = Table.AddIndexColumn(#"Added Column", "Index", 0, 1),
                    #"Added Custom" = Table.AddColumn(#"Added Index", "Name", each modelList{[Index]}),
                    #"Removed Columns" = Table.RemoveColumns(#"Added Custom", {"Index"}),
                    #"Added Column.Leaf" = Table.AddColumn(#"Removed Columns", "IsLeaf", each false, type logical),
                    navTable = Table.ToNavigationTable(
                        #"Added Column.Leaf", {"Name"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf"
                    )
                in
                    navTable
            else
                let
                    projectsTable = GetProjectsQuery(region),
                    elementsData = Table.AddColumn(
                        projectsTable, "Data", each GetFolderContent(region, [rootId]), type table
                    ),
                    projectsNavTable = WrapAsNavTable(elementsData, "Folder", false)
                in
                    projectsNavTable
    in
        navTable;
// Data Source Kind description
TrimbleConnectConnector = [
    Authentication = [
        OAuth = [
            StartLogin = StartLogin,
            FinishLogin = FinishLogin,
            Refresh = Refresh
        ]
    ],
    Label = "Trimble Identity"
];

GetFolderContent = (region as text, folderId as text) =>
    let
        folderItems = GetFolderItemsQuery(folderId),
        withDataColumn = Table.AddColumn(
            folderItems,
            "Data",
            each
                if Text.Contains([type], "Folder", Comparer.OrdinalIgnoreCase) then
                    @GetFolderContent(region, [id])
                else
                    GetModelEntities(region, [id]),
            type table
        ),
        withItemKindColumn = Table.AddColumn(
            withDataColumn,
            "ItemKind",
            each if Text.Contains([type], "Folder", Comparer.OrdinalIgnoreCase) then "Folder" else "Table",
            type text
        ),
        withPrimaryKey = Table.AddColumn(withItemKindColumn, "Primary key", each [id]),
        #"Renamed Column" = Table.RenameColumns(withPrimaryKey, {{"name", "Name"}}),
        withItemNameColumn = Table.AddColumn(#"Renamed Column", "ItemName", each [Name], type text),
        withLeafColumn = Table.AddColumn(
            withItemNameColumn,
            "IsLeaf",
            each if Text.Contains([type], "Folder", Comparer.OrdinalIgnoreCase) then false else true,
            type logical
        ),
        navTable = Table.ToNavigationTable(
            withLeafColumn, {"Primary key"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf"
        )
    in
        navTable;

GetModelEntities = (region as text, modelId as text) =>
    let
        url = GetRegionalModelEnpoint(region) & "models/" & modelId & "/entities?&include=psets,psets.name",
        content = FetchPages(url, 1000),
        expandedRecords = Table.ExpandRecordColumn(
            content, "Column1", {"id", "type", "psets"}, {"id", "type", "psets"}
        ),
        rowPerProperty = Table.ExpandListColumn(expandedRecords, "psets"),
        expandedPSets = Table.ExpandRecordColumn(
            rowPerProperty, "psets", {"idx", "name", "values"}, {"pset.idx", "pset.name", "pset.values"}
        ),
        psetDefs = GetPSetDefs(region, modelId),
        output = MergeEntitiesWithPSetDefs(expandedPSets, psetDefs)
    in
        output;

GetPSetDefs = (region as text, modelId as text) =>
    let
        url = GetRegionalModelEnpoint(region) & "models/" & modelId & "/psetdefs?",
        content = FetchPages(url, 30000),
        expandedRecords = Table.ExpandRecordColumn(
            content, "Column1", {"idx", "name", "props"}, {"idx", "name", "prop"}
        ),
        expanedPropsToRecords = Table.ExpandListColumn(expandedRecords, "prop"),
        expandedProperties = Table.ExpandRecordColumn(
            expanedPropsToRecords, "prop", {"name", "type"}, {"prop.name", "prop.type"}
        ),
        groupedPSets = Table.Group(
            expandedProperties,
            {"idx"},
            {
                {
                    "Grouped",
                    each _,
                    type table [
                        items.idx = nullable number,
                        items.name = nullable text,
                        items.prop.name = nullable text,
                        items.prop.type = nullable text
                    ]
                }
            }
        ),
        withIndexColumn = Table.AddColumn(
            groupedPSets, "TableWithIndex", each Table.AddIndexColumn([Grouped], "prop.index", 0, 1)
        ),
        onlyWithIndicies = Table.SelectColumns(withIndexColumn, {"TableWithIndex"}),
        output = Table.ExpandTableColumn(
            onlyWithIndicies,
            "TableWithIndex",
            {"idx", "name", "prop.name", "prop.type", "prop.index"},
            {"idx", "name", "prop.name", "prop.type", "prop.index"}
        ),
        changedTypes = Table.TransformColumnTypes(
            output,
            {
                {"idx", Int64.Type},
                {"name", type text},
                {"prop.name", type text},
                {"prop.type", type text},
                {"prop.index", Int64.Type}
            }
        )
    in
        changedTypes;

MergeEntitiesWithPSetDefs = (entities as table, psetdefs as table) =>
    let
        expandedValues = Table.ExpandListColumn(entities, "pset.values"),
        groupedByPSet = Table.Group(
            expandedValues,
            {"id", "pset.name"},
            {
                {
                    "Grouped",
                    each _,
                    type table [
                        items.id = text,
                        items.type = text,
                        items.psets.idx = number,
                        psetName = text,
                        items.psets.values = text
                    ]
                }
            }
        ),
        addedIndex = Table.AddColumn(
            groupedByPSet, "WithIndex", each Table.AddIndexColumn([Grouped], "prop.index", 0, 1)
        ),
        withIndex = Table.SelectColumns(addedIndex, {"WithIndex"}),
        expanded = Table.ExpandTableColumn(
            withIndex,
            "WithIndex",
            {"id", "type", "pset.idx", "pset.name", "pset.values", "prop.index"},
            {"id", "type", "pset.idx", "pset.name", "prop.value", "prop.index"}
        ),
        finalTypes = Table.TransformColumnTypes(
            expanded,
            {
                {"id", type text},
                {"type", type text},
                {"pset.idx", Int64.Type},
                {"pset.name", type text},
                {"prop.value", type text},
                {"prop.index", Int64.Type}
            }
        ),
        merged = Table.NestedJoin(
            finalTypes, {"pset.idx", "prop.index"}, psetdefs, {"idx", "prop.index"}, "psetdefs", JoinKind.LeftOuter
        ),
        #"Expanded psetdefs" = Table.ExpandTableColumn(
            merged, "psetdefs", {"prop.name", "prop.type"}, {"prop.name", "prop.type"}
        ),
        #"Reordered Columns" = Table.ReorderColumns(
            #"Expanded psetdefs",
            {"id", "type", "pset.idx", "pset.name", "prop.name", "prop.value", "prop.type", "prop.index"}
        ),
        #"Removed Columns" = Table.RemoveColumns(#"Reordered Columns", {"prop.index", "pset.idx"}),
        #"Renamed Columns" = Table.RenameColumns(
            #"Removed Columns",
            {
                {"type", "Object Type"},
                {"id", "Guid"},
                {"pset.name", "Property Set"},
                {"prop.name", "Name"},
                {"prop.value", "Value"},
                {"prop.type", "Unit"}
            }
        )
    in
        #"Renamed Columns";

GetRegionalModelEnpoint = (region as text) =>
    let
        uri =
            if Text.Contains(region, "North America") then
                "https://model-api11.connect.trimble.com/"
            else if Text.Contains(region, "Europe") then
                "https://model-api21.connect.trimble.com/"
            else if Text.Contains(region, "Asia") then
                "https://model-api31.connect.trimble.com/"
            else if Text.Contains(region, "Australia") then
                "https://model-api32.connect.trimble.com/"
            else
                error "Unknown region"
    in
        uri;

FetchPages = (url as text, pageSize as number) =>
    let
        Source = GenerateByPage(
            (previous) =>
                let
                    skipRows = if previous = null then 0 else Value.Metadata(previous)[skipRows],
                    totalItems = if previous = null then 0 else Value.Metadata(previous)[total],
                    table =
                        if previous = null or Table.RowCount(previous) = pageSize then
                            FetchPage(url, pageSize, skipRows)
                        else
                            null
                in
                    table,
            type table [Column1]
        )
    in
        Source;

//WrapAsNavTable assumes that input table has Data column
WrapAsNavTable = (tableWithDataColumn as table, itemKind as text, isLeaf as logical) as table =>
    let
        #"Added Column.Primary Key" = Table.AddColumn(tableWithDataColumn, "Primary key", each [id]),
        #"Renamed Column" = Table.RenameColumns(#"Added Column.Primary Key", {{"name", "Name"}}),
        #"Added Column.Kind" = Table.AddColumn(#"Renamed Column", "ItemKind", each itemKind, type text),
        #"Added Column.Name" = Table.AddColumn(#"Added Column.Kind", "ItemName", each itemKind, type text),
        #"Added Column.Leaf" = Table.AddColumn(#"Added Column.Name", "IsLeaf", each isLeaf, type logical),
        navTable = Table.ToNavigationTable(
            #"Added Column.Leaf", {"Primary key"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf"
        )
    in
        navTable;

Table.ToNavigationTable = (
    table as table,
    keyColumns as list,
    nameColumn as text,
    dataColumn as text,
    itemKindColumn as text,
    itemNameColumn as text,
    isLeafColumn as text
) as table =>
    let
        tableType = Value.Type(table),
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta [
            NavigationTable.NameColumn = nameColumn,
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn,
            Preview.DelayColumn = itemNameColumn,
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        navigationTable = Value.ReplaceType(table, newTableType)
    in
        navigationTable;

Extension.LoadFunction = (fileName as text) =>
    let
        binary = Extension.Contents(fileName), asText = Text.FromBinary(binary)
    in
        try
            Expression.Evaluate(asText, #shared) catch (e) =>
                error
                    [
                        Reason = "Extension.LoadFunction Failure",
                        Message.Format = "Loading '#{0}' failed - '#{1}': '#{2}'",
                        Message.Parameters = {fileName, e[Reason], e[Message]},
                        Detail = [File = fileName, Error = e]
                    ];

// Data Source UI publishing description
TrimbleConnectConnector.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = {Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp")},
    LearnMoreUrl = "https://powerbi.microsoft.com/",
    SourceImage = TrimbleConnectConnector.Icons,
    SourceTypeImage = TrimbleConnectConnector.Icons
];

TrimbleConnectConnector.Icons = [
    Icon16 = {
        Extension.Contents("TrimbleConnectConnector16.png"),
        Extension.Contents("TrimbleConnectConnector20.png"),
        Extension.Contents("TrimbleConnectConnector24.png"),
        Extension.Contents("TrimbleConnectConnector32.png")
    },
    Icon32 = {
        Extension.Contents("TrimbleConnectConnector32.png"),
        Extension.Contents("TrimbleConnectConnector40.png"),
        Extension.Contents("TrimbleConnectConnector48.png"),
        Extension.Contents("TrimbleConnectConnector64.png")
    }
];
