SET NOCOUNT ON;

DECLARE @TableName VARCHAR(50) = '', -- Table Name.
        @Clause NVARCHAR(MAX) = ''; -- Any specific condition for the table.
DECLARE @SkipFields NVARCHAR(MAX) = '',
        @Query NVARCHAR(MAX) = '',
        @ColumnsCount INT = 0,
        @ColumnName NVARCHAR(100) = '',
        @ColumnDataType NVARCHAR(100) = '',
        @SubQuery NVARCHAR(MAX) = '',
        @SubQueryResult NVARCHAR(MAX) = '',
        @TempTableQuery NVARCHAR(MAX) = ''
DECLARE @Columns AS TABLE
(
    Id INT IDENTITY(1, 1),
    ColumnName VARCHAR(100),
    DataType VARCHAR(100)
)

IF (ISNULL(@Clause, '') <> '')
BEGIN
    SET @Clause = ' WHERE ' + @Clause
END
ELSE
BEGIN
    SET @Clause = ''
END

INSERT INTO @Columns
SELECT C.COLUMN_NAME,
       (CASE
            WHEN C.DATA_TYPE IN ( 'decimal', 'numeric' ) THEN
                C.DATA_TYPE + '(' + CAST(ISNULL(C.NUMERIC_PRECISION, 8) AS VARCHAR(100)) + ','
                + CAST(ISNULL(C.NUMERIC_SCALE, 8) AS VARCHAR(100)) + ')'
            WHEN C.DATA_TYPE IN ( 'varchar', 'nvarchar', 'char' ) THEN
                C.DATA_TYPE + '('
                + CAST((CASE
                            WHEN C.CHARACTER_OCTET_LENGTH = -1 THEN
                                'max'
                            ELSE
                                CAST(C.CHARACTER_OCTET_LENGTH / (CASE
                                                                     WHEN C.DATA_TYPE = 'nvarchar' THEN
                                                                         2
                                                                     ELSE
                                                                         1
                                                                 END
                                                                ) AS VARCHAR(100))
                        END
                       ) AS VARCHAR(100)) + ')'
            ELSE
                DATA_TYPE
        END
       )
FROM sys.tables T
    INNER JOIN INFORMATION_SCHEMA.COLUMNS C
        ON C.TABLE_NAME = T.name
OUTER APPLY (
	Select value 
	from string_split(@SkipFields, ',')
) SF
WHERE name = @TableName
AND COLUMN_NAME <> SF.value
AND DATA_TYPE NOT IN ('TIMESTAMP')

SELECT @ColumnsCount = COUNT(*)
FROM @Columns

Declare @SelectedColumns NVARCHAR(MAX) = '';

Select @SelectedColumns = @SelectedColumns + ColumnName +  ', '
FROM @Columns

SET @SelectedColumns = SUBSTRING(@SelectedColumns, 0, LEN(@SelectedColumns))

IF OBJECT_ID('tempdb..#Temp') IS NOT NULL
    DROP TABLE #Temp

CREATE TABLE #Temp
(
    RowNum INT
)

DECLARE @UpdateTemp NVARCHAR(MAX) = ' ALTER TABLE #Temp ADD ';

SET @UpdateTemp = @UpdateTemp + ' ';

SELECT @UpdateTemp = @UpdateTemp + ' ' + ColumnName + ' ' + DataType + ', '
FROM @Columns

SET @UpdateTemp = SUBSTRING(@UpdateTemp, 0, LEN(@UpdateTemp))

EXEC (@UpdateTemp)

SET @TempTableQuery = 'Select RowNum = ROW_NUMBER() OVER (ORDER BY (SELECT 1)), ' + @SelectedColumns + ' FROM ' + @TableName + @Clause

INSERT INTO #Temp
EXEC (@TempTableQuery)

DECLARE @RowsCount INT =
        (
            SELECT COUNT(*)FROM #Temp
        )

DECLARE @TableRowNumber INT = 1

WHILE (@TableRowNumber <= @RowsCount)
BEGIN
    DECLARE @I INT = 1
    SET @Query = 'new ' + @TableName + ' {';
    WHILE (@I <= @ColumnsCount)
    BEGIN
        SELECT @ColumnName = ColumnName,
               @ColumnDataType = DataType
        FROM @Columns
        WHERE Id = @I

        SET @SubQuery
            = 'Select TOP 1  @SubQueryResult = CAST(' + @ColumnName + ' AS NVARCHAR(MAX)) FROM #Temp WHERE RowNum = '
              + CAST(@TableRowNumber AS VARCHAR(50)) + ''

        EXEC sp_executeSQl @SubQuery,
                           N'@SubQueryResult nvarchar(max) output',
                           @SubQueryResult OUTPUT

        IF (@SubQueryResult IS NULL)
        BEGIN
            SET @SubQueryResult = 'null';
        END

        IF (@SubQueryResult <> 'null')
        BEGIN
            IF (
                   ISNULL(@SkipFields, '') <> ''
                   AND EXISTS
            (
                SELECT 1
                FROM STRING_SPLIT(@SkipFields, ',')
                WHERE value = @ColumnName
            )
               )
            BEGIN
                SET @SubQueryResult = '""';
            END
            ELSE
            BEGIN
                IF (@ColumnDataType IN ( 'DATETIME', 'DATETIME2' ))
                BEGIN
                    SET @SubQueryResult = 'DateTime.Parse("' + @SubQueryResult + '")';
                END
                ELSE IF (@ColumnDataType = 'BIT')
                BEGIN
                    SET @SubQueryResult = CASE
                                              WHEN @SubQueryResult = '1' THEN
                                                  'true'
                                              ELSE
                                                  'false'
                                          END
                END
                ELSE IF (
                            @ColumnDataType NOT IN ( 'INT', 'TINYINT', 'BIGINT' )
                            AND @ColumnDataType NOT LIKE 'DECIMAL%'
                            AND @ColumnDataType NOT LIKE 'NUMERIC%'
                        )
                BEGIN
                    SET @SubQueryResult = '"' + @SubQueryResult + '"';
                END
            END
        END

        SET @Query = @Query + ' ' + @ColumnName + ' = ' + @SubQueryResult

        IF (@I < @ColumnsCount)
        BEGIN
            SET @Query = @Query + ', '
        END

        SET @I = @I + 1;
    END

    SET @Query = @Query + ' },'

    PRINT (@Query)

    SET @TableRowNumber = @TableRowNumber + 1;
END

IF OBJECT_ID('tempdb..#Temp') IS NOT NULL
    DROP TABLE #Temp
