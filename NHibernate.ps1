cls
$env:APPLICATIONPATH = "YourApplicationPath"
$env:SERVER = "YourServer"
$env:DATABASE = "AdventureWorks"
$env:ASSEMBLY = "NHQuickStart"
$env:NAMESPACE = "NHQuickStart.Models"
$env:SCHEMATOPATH = "Y"
$env:FORCE = "Y"
$env:PASCALCASE = "Y"
$env:TABLES = "*"

$path2Models = Join-Path $(Join-Path $env:APPLICATIONPATH $env:ASSEMBLY) "Models"
$path2Maps = Join-Path $(Join-Path $env:APPLICATIONPATH $env:ASSEMBLY) "Maps"
$schema2path = $(if ($env:SCHEMATOPATH -ieq "Y") { $true } else { $false } )
$force = $(if ($env:FORCE -ieq "Y") { $true } else { $false } )
$pascalCase = $(if ($env:PASCALCASE -ieq "Y") { $true } else { $false } )
$xtables = @()
$env:TABLES -split "," | ForEach-Object {
    $tbl = $_ -split "."
    if ($tbl.Count -eq 1)
    {
        $xtables += @("dbo", $tbl[0]) -join "."
    } else {
        $xtables += $_
    }
}
$xtables

$tblQuery = @"
SELECT *, COLUMNPROPERTY(OBJECT_ID(TABLE_SCHEMA+'.'+TABLE_NAME), COLUMN_NAME, 'ISIDENTITY') [ISIDENTITY]
 FROM INFORMATION_SCHEMA.COLUMNS C
WHERE NOT EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.VIEWS V WHERE V.TABLE_SCHEMA = C.TABLE_SCHEMA AND V.TABLE_NAME = C.TABLE_NAME)
ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
"@

$viewQuery = @"
SELECT * FROM INFORMATION_SCHEMA.COLUMNS C
WHERE EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.VIEWS V WHERE V.TABLE_SCHEMA = C.TABLE_SCHEMA AND V.TABLE_NAME = C.TABLE_NAME)
ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
"@

$keyQuery = @"
SELECT KU.TABLE_SCHEMA,KU.TABLE_NAME,COLUMN_NAME, KU.ORDINAL_POSITION
FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS AS TC
INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS KU
	ON TC.CONSTRAINT_TYPE = 'PRIMARY KEY' 
    AND TC.CONSTRAINT_NAME = KU.CONSTRAINT_NAME
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

$vcolumns = Invoke-Sqlcmd -ServerInstance $env:SERVER -Database $env:DATABASE `
    -Query $viewQuery

$keys = Invoke-Sqlcmd -ServerInstance "NewEnvy\SQLExpress" -Database AdventureWorks `
    -Query $keyQuery

$fKeys = Invoke-Sqlcmd -ServerInstance "NewEnvy\SQLExpress" -Database AdventureWorks `
    -Query $fkeyQuery

$tables = $columns | Select-Object -Property TABLE_SCHEMA, TABLE_NAME -Unique

$nhibernate = $tables | Where-Object {
    $env:TABLES -eq "*" -or $xtables -icontains $("{0}.{1}" -f $_.TABLE_SCHEMA, $_.TABLE_NAME)
} | ForEach-Object `
{
    
    $namespace = $env:NAMESPACE
    $assembly = $env:ASSEMBLY
    if ($_.TABLE_SCHEMA -ne "dbo") { $namespace += "." + $_.TABLE_SCHEMA }
    $schema = $_.TABLE_SCHEMA
#    $table = $_.TABLE_NAME
    $table = $(if ($pascalCase) { $(Get-Culture).TextInfo.ToTitleCase($($_.TABLE_NAME.ToLower() -replace "_", " ")) -replace " ", "-" } else { $_.TABLE_NAME } )
    $tableKeys = $keys | Where-Object { $_.TABLE_SCHEMA -ieq $schema -and $_.TABLE_NAME -ieq $table } | Select-Object -Property Column_Name | % { $_.Column_Name }

    $tableClass = @"
using System;
using System.Text;
using System.Collections.Generic;

namespace {0}
{{{{
    public class {1}
    {{{{
        public {1}() {{{{ }}}}
{{0}}{{1}}
    }}}}
}}}}
"@ -f $namespace, $table
    $tableMap = @"
<?xml version="1.0" encoding="utf-8" ?>
<hibernate-mapping assembly="{4}" namespace="{3}" xmlns="urn:nhibernate-mapping-2.2">
  <class name="{0}" table="{1}" schema="{2}" lazy="true" >
{{0}}
  </class>
</hibernate-mapping>
"@ -f $table, $_.TABLE_NAME, $schema, $namespace, $assembly

    $tableColumns = @()
    $mapColumns = @()
    $pkColumns = $keys | Where-Object { $_.TABLE_SCHEMA -eq $schema -and $_.TABLE_NAME -ieq $table } | 
        Sort-Object -Property Ordinal_Position |
        Select-Object -Property Column_Name |
        ForEach-Object { 
            $xcolumn = $(if ($_.Column_Name -match "^[\d]*$") { "_" } else { "" }) + $_.COLUMN_NAME
            if ($xcolumn -ieq $table) { $xcolumn += "val" }
            $xcolumn
        }
    $pkcolumns
    $compositeKey = ""
    $compositeKey = if ($pkColumns.Count -gt 1) {
        @"

        #region NHibernate Composite Key Requirements
        public override bool Equals(object obj) {{
            if (obj == null) return false;
            var t = obj as $table;
            if (t == null) return false;
            if ({0}) 
                return true;

            return false;
        }}
        public override int GetHashCode() {{
            int hash = GetType().GetHashCode();
            {1}

            return hash;
        }}
        #endregion
"@ -f $(($pkColumns | Sort-Object | ForEach-Object { "{0} == t.{0}" -f `
        $(if ($pascalCase) { $(Get-Culture).TextInfo.ToTitleCase($($_.ToLower() -replace "_", " ")) -replace " ", "-" } else { $_ }) }) -join "`r`n`t`t`t&& "),
    $(($pkColumns | Sort-Object | ForEach-Object { "hash = (hash * 397) ^ {0}.GetHashCode();" -f `
        $(if ($pascalCase) { $(Get-Culture).TextInfo.ToTitleCase($($_.ToLower() -replace "_", " ")) -replace " ", "-" } else { $_ }) }) -join "`r`n`t`t`t")
    } -join "`r`n"
    $compositeMap = $(if ($pkColumns.Count -gt 1) {
        "`t`t<composite-id>`r`n{0}`r`n`t`t</composite-id>{{0}}" `
            -f $(($pkColumns | ForEach-Object { "`t`t`t<key-property name=`"{1}`" column=`"{0}`" />" -f `
            $_, $(if ($pascalCase) { $(Get-Culture).TextInfo.ToTitleCase($($_.ToLower() -replace "_", " ")) -replace " ", "-" } else { $_ }) }) -join "`r`n")
    } else { "" }) -join "`r`n"

    $columns | 
        Where-Object { $_.TABLE_SCHEMA -eq $schema -and $_.TABLE_NAME -ieq $table } | 
        Select-Object -Property Column_Name, Is_Nullable, Data_Type, IsIdentity | 
        ForEach-Object { 
            $sqldatatype = $_.Data_Type
            $datatype = $_.Data_Type
#            if ($pascalCase) { 
#                $dataype = $(Get-Culture).TextInfo.ToTitleCase($($datatype.ToLower() -replace "_", " ")) -replace " ", "-" 
#            }
            switch -Regex ($_.Data_Type)
            {
                "n?varchar|n?char|xml|geography|phonenumbertype|hierarchyid" { $datatype = "string" }
                "money" { $datatype = "decimal" }
                "numeric" { $datatype = "double" }
                "bit" { $datatype = "bool" }
                "int" { $datatype = "long" }
                "smallint" { $datatype = "int" }
                "tinyint" { $datatype = "short" }
                "uniqueidentifier" { $datatype = "System.Guid" }
                "date|sdatetime|time" { $datatype = "DateTime" }
                "varbinary" { $datatype = "byte[]" }
            }
            $column = $_.Column_Name
            $xcolumn = $(if ($_.Column_Name -match "^[\d]*$") { "_" } else { "" }) + $_.COLUMN_NAME
            if ($xcolumn -ieq $table) { $xcolumn += "val" }
            if ($pascalCase) { $xcolumn = $(Get-Culture).TextInfo.ToTitleCase($($xcolumn.ToLower() -replace "_", " ")) -replace " ", "-" }
            $fkeydef = ($fkeys |
                Where-Object { $_.FK_SCHEMA -ieq $schema -and $_.FK_TABLE_NAME -ieq $table -and $_.FK_COLUMN_NAME -ieq $column } |
                ForEach-Object { 
                    $fcolumn = $_.FK_COLUMN_NAME
                    if (!$pascalCase) { $fxcolumn = $_.REFERENCED_TABLE_NAME }
                    else { $fxcolumn = $(Get-Culture).TextInfo.ToTitleCase($($_.REFERENCED_TABLE_NAME.ToLower() -replace "_", " ")) -replace " ", "-" }
                    $fschema = $(if ($_.FK_SCHEMA -ieq $_.REFERENCED_SCHEMA) { "" } else { "{0}." -f $_.REFERENCED_SCHEMA })
                    $nullable = $(if ($_.Is_Nullable -ine "YES") {  " not-null=`"true`"" } else { " not-null=`"false`"" })
                    "`r`n`t`tpublic virtual {2}{1} {0} {{ get; set; }}" -f $fxcolumn, $fxcolumn, $fschema
                }) -join "`r`n"

            $tableColumns += "`t`tpublic virtual {0}{3} {1} {{ get; set; }}{2}{4}" -f $DataType, $xcolumn, 
                $(if ($_.Is_Nullable -ieq "NO") { "`t// NOT NULL" } else { "" }),
                $(if ($_.Is_Nullable -ieq "YES" -and @("string","byte[]") -notcontains $datatype) { "?" } else { "" }),
                $fkeydef

            $identity = $(if($_.IsIdentity -eq "1") { "`r`n`t`t`t<generator class=`"identity`" />" } else { "" } )
<#
            $labelfmt = if ($pkColumns.Count -le 1)
            {
                $(if ($tableKeys -icontains $_.Column_Name)
                { "`t`t<id name=`"{1}`">`r`n`t`t`t<column name=`"{0}`" sql-type=`"{4}`"{3} />{6}`r`n`t`t</id>{5}" } 
                else { "`t`t<property name=`"{1}`">`r`n`t`t`t<column name=`"{0}`" sql-type=`"{4}`"{3} />`r`n`t`t</property>{5}" } )
            } elseif ($pkColumns -icontains $_.Column_Name) { "" } 
                else { "`t`t<property name=`"{1}`">`r`n`t`t`t<column name=`"{0}`" sql-type=`"{4}`"{3} />`r`n`t`t</property>{5}" }
#>
            $nullable = $(if ($_.Is_Nullable -ine "YES") {  " not-null=`"true`"" } else { " not-null=`"false`"" })
            $fkeydef = "`r`n" + ($fkeys |
                Where-Object { $_.FK_SCHEMA -ieq $schema -and $_.FK_TABLE_NAME -ieq $table -and $_.FK_COLUMN_NAME -ieq $column } |
                ForEach-Object { 
                    $fcolumn = $_.FK_COLUMN_NAME
                    if (!$pascalCase) { $fxcolumn = $_.REFERENCED_TABLE_NAME }
                    else { $fxcolumn = $(Get-Culture).TextInfo.ToTitleCase($($_.REFERENCED_TABLE_NAME.ToLower() -replace "_", " ")) -replace " ", "-" }
                    $nullable = $(if ($_.Is_Nullable -ine "YES") {  " not-null=`"true`"" } else { " not-null=`"false`"" })
                    "`t`t<many-to-one name=`"{1}`">`r`n`t`t`t<column name=`"{0}`" sql-type=`"{3}`"{2} />`r`n`t`t</many-to-one>" -f $fColumn, $fxcolumn, $nullable, $sqlDataType
                }) -join "`r`n"
            if ($pkColumns -inotcontains $xcolumn)
            {
                $labelfmt = "`t`t<property name=`"{1}`">`r`n`t`t`t<column name=`"{0}`" sql-type=`"{4}`"{3} />`r`n`t`t</property>{5}"
                $mapColumns += $labelfmt -f $Column, $xcolumn, $DataType, $nullable, $sqlDataType, $fkeydef, $identity
            } elseif ($pkColumns.Count -eq 1)
            {
                $labelfmt = "`t`t<id name=`"{1}`">`r`n`t`t`t<column name=`"{0}`" sql-type=`"{4}`"{3} />{6}`r`n`t`t</id>{5}"
                $mapColumns += $labelfmt -f $Column, $xcolumn, $DataType, $nullable, $sqlDataType, $fkeydef, $identity
            } else {
                $mapColumns += $compositeMap -f $fkeydef
                $compositeMap = "{0}"
            }
        }
        $fkeybags = ($fkeys | Where-Object { $_.REFERENCED_SCHEMA -ieq $schema -and $_.REFERENCED_TABLE_NAME -ieq $table -and $tableKeys -icontains $_.FK_COLUMN_NAME } | 
            ForEach-Object {
                $fk = $_
                    @"
    <bag name="{1}">
        <key column="{2}" />
        <one-to-many class="{1}" />
    </bag>
"@ -f $fk.FK_SCHEMA, $($(Get-Culture).TextInfo.ToTitleCase($($fk.FK_TABLE_NAME.ToLower() -replace "_", " ")) -replace " ", "-"), $fk.FK_COLUMN_NAME
        }) -join "`r`n"
        #$mapColumns += $(if ($fkeybags -ne "") { "`r`n{0}" -f $fkeybags } else { "" })

    New-Object -TypeName PSObject -Property @{
        schema = $(if ($schema -ieq "dbo") { "" } else { $schema })
        table = $table
        class = $($tableClass -f ($tableColumns -join "`r`n"), $compositeKey)
        keys = $tableKeys
        #columns = $tableColumns
        map = $($tableMap -f ($mapColumns -join "`r`n"))
#        fkeys = $(if ($fkColumns) { $fkColumns } else { "`t`tNONE" })
    }
}

$nhibernate | ForEach-Object `
{
    $class = $_.class
    $map = $_.map
    $schema = $_.schema
    $csFile = "{0}.cs" -f $_.table
    $xmlFile = "{0}.hbm.xml" -f $_.table
    #$_.fkeys
    $ModelPath = $path2Models
    if ($_.schema -ne "" -and $schema2path)
    {
        $ModelPath = Join-Path $ModelPath $schema
        if (![IO.Directory]::Exists($ModelPath)) { [IO.Directory]::CreateDirectory($ModelPath) }
    }
    $ModelPath = Join-Path $ModelPath $csFile
    if ($force -or ![IO.File]::Exists($ModelPath)) { 
        if ([IO.File]::Exists($ModelPath)) { [IO.File]::Delete($ModelPath) }
        $class | Out-File $ModelPath -ErrorAction Continue -Force ascii 
    }

    $ModelPath = $path2Maps
    if ($_.schema -ne "" -and $schema2path)
    {
        $ModelPath = Join-Path $ModelPath $schema
        if (![IO.Directory]::Exists($ModelPath)) { [IO.Directory]::CreateDirectory($ModelPath) }
    }
    $ModelPath = Join-Path $ModelPath $xmlFile
    if ($force -or ![IO.File]::Exists($ModelPath)) { 
        if ([IO.File]::Exists($ModelPath)) { [IO.File]::Delete($ModelPath) }
        $map | Out-File $ModelPath -ErrorAction Continue -Force utf8 
    }
}
