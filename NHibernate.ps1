cls
$env:APPLICATIONPATH = "YourApplicationPath"
$env:SERVER = "YourServer"
$env:ASSEMBLY = "NHQuickStart"
$env:NAMESPACE = "NHQuickStart.Models"
$env:DATABASE = "AdventureWorks"
$env:SCHEMATOPATH = "Y"
$env:FORCE = "Y"

$path2Models = Join-Path $(Join-Path $env:APPLICATIONPATH $env:ASSEMBLY) "Models"
$path2Maps = Join-Path $(Join-Path $env:APPLICATIONPATH $env:ASSEMBLY) "Maps"

$tblQuery = @"
select * from INFORMATION_SCHEMA.COLUMNS c
where not exists(select 1 from INFORMATION_SCHEMA.VIEWS v where v.TABLE_SCHEMA = c.TABLE_SCHEMA and v.TABLE_NAME = c.TABLE_NAME)
order by table_schema, table_name, ordinal_position
"@

$viewQuery = @"
select * from INFORMATION_SCHEMA.COLUMNS c
where exists(select 1 from INFORMATION_SCHEMA.VIEWS v where v.TABLE_SCHEMA = c.TABLE_SCHEMA and v.TABLE_NAME = c.TABLE_NAME)
order by table_schema, table_name, ordinal_position
"@

$keyQuery = @"
SELECT KU.TABLE_SCHEMA,KU.table_name,column_name
FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS AS TC
INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS KU
	ON TC.CONSTRAINT_TYPE = 'PRIMARY KEY' AND
		TC.CONSTRAINT_NAME = KU.CONSTRAINT_NAME
ORDER BY KU.TABLE_SCHEMA, KU.TABLE_NAME, KU.ORDINAL_POSITION;
"@

$fkeyQuery = @"
SELECT  
     KCU1.CONSTRAINT_NAME AS FK_CONSTRAINT_NAME 
	,KCU1.TABLE_SCHEMA as FK_SCHEMA
    ,KCU1.TABLE_NAME AS FK_TABLE_NAME 
    ,KCU1.COLUMN_NAME AS FK_COLUMN_NAME 
    ,KCU1.ORDINAL_POSITION AS FK_ORDINAL_POSITION 
    ,KCU2.CONSTRAINT_NAME AS REFERENCED_CONSTRAINT_NAME 
	,KCU2.TABLE_SCHEMA as REFERENCED_SCHEMA
    ,KCU2.TABLE_NAME AS REFERENCED_TABLE_NAME 
    ,KCU2.COLUMN_NAME AS REFERENCED_COLUMN_NAME 
    ,KCU2.ORDINAL_POSITION AS REFERENCED_ORDINAL_POSITION 
FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS AS RC 

INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS KCU1 
    ON KCU1.CONSTRAINT_CATALOG = RC.CONSTRAINT_CATALOG  
    AND KCU1.CONSTRAINT_SCHEMA = RC.CONSTRAINT_SCHEMA 
    AND KCU1.CONSTRAINT_NAME = RC.CONSTRAINT_NAME 

INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS KCU2 
    ON KCU2.CONSTRAINT_CATALOG = RC.UNIQUE_CONSTRAINT_CATALOG  
    AND KCU2.CONSTRAINT_SCHEMA = RC.UNIQUE_CONSTRAINT_SCHEMA 
    AND KCU2.CONSTRAINT_NAME = RC.UNIQUE_CONSTRAINT_NAME 
    AND KCU2.ORDINAL_POSITION = KCU1.ORDINAL_POSITION 
"@

$columns = Invoke-Sqlcmd -ServerInstance $env:SERVER -Database $env:DATABASE `
    -Query $tblQuery
#$columns | Where-Object { $_.TABLE_NAME -eq "Person" }| Select-Object -First 1
#$columns | Format-Table -AutoSize -Wrap -Property TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, IS_NULLABLE, DATA_TYPE

$vcolumns = Invoke-Sqlcmd -ServerInstance $env:SERVER -Database $env:DATABASE `
    -Query $viewQuery
#$vcolumns | Where-Object { $_.TABLE_NAME -eq "Person" }| Select-Object -First 1

$keys = Invoke-Sqlcmd -ServerInstance "NewEnvy\SQLExpress" -Database AdventureWorks `
    -Query $keyQuery
#$keys | Format-Table -AutoSize -Wrap

$fKeys = Invoke-Sqlcmd -ServerInstance "NewEnvy\SQLExpress" -Database AdventureWorks `
    -Query $fkeyQuery
#$fKeys | Where-object {$_.Referenced_Table_Name -ieq "Person" } | Select-Object -First 1 | Format-List
#$fKeys | Format-Table -AutoSize -Wrap

$tables = $columns | Select-Object -Property TABLE_SCHEMA, TABLE_NAME -Unique
#$tables | Format-Table -AutoSize -Wrap

$nhibernate = $tables | ForEach-Object `
{
    
    $namespace = $env:NAMESPACE
    $assembly = $env:ASSEMBLY
    if ($_.TABLE_SCHEMA -ne "dbo") { $namespace += "." + $_.TABLE_SCHEMA }
    $schema = $_.TABLE_SCHEMA
    $table = $_.TABLE_NAME
    $tableKeys = $keys | Where-Object { $_.TABLE_SCHEMA -eq $schema -and $_.TABLE_NAME -eq $table } | Select-Object -Property Column_Name | % { $_.Column_Name }

    $tableClass = "using System;`r`nusing System.Collections.Generic;`r`n`r`nnamespace {0}`r`n{{{{`r`n`tpublic class {1}`r`n`t{{{{`r`n{{0}}`r`n`t}}}}`r`n}}}}" -f $namespace, $table
    $tableMap = @"
<?xml version="1.0" encoding="utf-8" ?>
<hibernate-mapping xmlns="urn:nhibernate-mapping-2.2" namespace="{2}" assembly="{3}">
  <class name="{0}" table="{0}" schema="{1}">
{{0}}
  </class>
</hibernate-mapping>
"@ -f $table, $schema, $namespace, $assembly

    $fkColumns = ($fkeys |
        Where-Object { $_.FK_SCHEMA -ieq $schema -and $_.FK_TABLE_NAME -ieq $table } |
        ForEach-Object {
        "`t`tFK: {0}`tCN: {1}`tS: {2}`tT: {3}`tC: {4}`tO: {5}" -f `
            $_.FK_CONSTRAINT_NAME, $_.REFERENCED_CONSTRAINT_NAME, $_.REFERENCED_SCHEMA, $_.REFERENCED_TABLE_NAME, $_.REFERENCED_COLUMN_NAME, $_.REFERENCED_ORDINAL_POSITION
    }) -join "`r`n"

    $tableColumns = ($columns | 
        Where-Object { $_.TABLE_SCHEMA -eq $schema -and $_.TABLE_NAME -eq $table } | 
        Select-Object -Property Column_Name, Is_Nullable, Data_Type | 
        ForEach-Object { 
            $datatype = $_.Data_Type
            switch -Regex ($_.Data_Type)
            {
                "n?varchar|n?char" { $datatype = "string" }
                "money" { $datatype = "double" }
                "bit" { $datatype = "bool" }
                "int" { $datatype = "Int64" }
                "smallint" { $datatype = "Int32" }
                "tinyint" { $datatype = "Int16" }
                "xml" { $datatype = "string" }
                "uniqueidentifier" { $datatype = "Guid" }
                "date|sdatetime" { $datatype = "DateTime" }
                "hierarchyid" { $datatype = "string" }
            }
            "`t`tpublic virtual {0}{3} {1} {{ get; set; }}{2}" -f $DataType, $_.Column_Name, 
                $(if ($_.Is_Nullable -ieq "NO") { "`t// NOT NULL" } else { "" }),
                $(if ($_.Is_Nullable -ine "NO" -and $datatype -ne "string") { "?" } else { "" })
        }) -join "`r`n"

    $mapColumns = ($columns | 
        Where-Object { $_.TABLE_SCHEMA -eq $schema -and $_.TABLE_NAME -eq $table } | 
        Select-Object -Property Column_Name, Is_Nullable, Data_Type | 
        ForEach-Object { 
            $datatype = $_.Data_Type
            switch -Regex ($_.Data_Type)
            {
                "n?varchar|n?char" { $datatype = "string" }
                "money" { $datatype = "double" }
                "bit" { $datatype = "bool" }
                "int" { $datatype = "Int64" }
                "smallint" { $datatype = "Int32" }
                "tinyint" { $datatype = "Int16" }
                "xml" { $datatype = "string" }
                "uniqueidentifier" { $datatype = "Guid" }
                "date|datetime" { $datatype = "DateTime" }
            }
            $column = $_.Column_Name
            $label = $(if ($tableKeys -icontains $_.Column_Name) { "id" } else { "property" } )
            $nullable = $(if ($_.Is_Nullable -ine "YES") {  " not-null=`"true`"" } else { "" })
            switch ($label)
            {
                "id" {
                    "`t`t<id name=`"{0}`">`r`n`t`t`t<column name=`"{0}`" sql-type=`"{1}`"{2} />`r`n`t`t</id>" -f $Column, $_.Data_Type, $nullable
                }
                "property" {
                    "`t`t<property name=`"{0}`" type=`"{1}`"{2} />" -f $Column, $DataType, $nullable
                }
            }
        }) -join "`r`n"

    New-Object -TypeName PSObject -Property @{
        schema = $(if ($schema -ieq "dbo") { "" } else { $schema })
        table = $table
        class = $($tableClass -f $tableColumns)
        keys = $tableKeys
        #columns = $tableColumns
        map = $($tableMap -f $mapColumns)
        fkeys = $(if ($fkColumns) { $fkColumns } else { "`t`tNONE" })
    }
}

$schema2path = $(if ($env:SCHEMATOPATH -ieq "Y") { $true } else { $false } )
$force = $(if ($env:FORCE -ieq "Y") { $true } else { $false } )

$nhibernate | ForEach-Object `
{
    $class = $_.class
    $map = $_.map
    $schema = $_.schema
    $csFile = "{0}.cs" -f $_.table
    $xmlFile = "{0}.hbm.xml" -f $_.table
    $_.fkeys
    $ModelPath = $path2Models
    if ($_.schema -ne "" -and $schema2path)
    {
        $ModelPath = Join-Path $ModelPath $schema
        if (![IO.Directory]::Exists($ModelPath)) { [IO.Directory]::CreateDirectory($ModelPath) }
    }
    $ModelPath = Join-Path $ModelPath $csFile
    if ($force -or ![IO.File]::Exists($ModelPath)) { 
        #"model: $ModelPath"
        $class | Out-File $ModelPath -ErrorAction Continue -Force ascii 
    }

    $ModelPath = $path2Models
    if ($_.schema -ne "" -and $schema2path)
    {
        $ModelPath = Join-Path $ModelPath $schema
        if (![IO.Directory]::Exists($ModelPath)) { [IO.Directory]::CreateDirectory($ModelPath) }
    }
    $ModelPath = Join-Path $ModelPath $xmlFile
    if ($force -or ![IO.File]::Exists($ModelPath)) { 
        #"map: $ModelPath"
        $map | Out-File $ModelPath -ErrorAction Continue -Force utf8 
    }
}
