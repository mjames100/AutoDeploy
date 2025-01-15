





/*******************************************************************************************************
Stored Procedure		:	p_ExternalJSONBloomreach_SPS
DateCreated				:	2021-07-15
Author					:	Michael James
Description				:	This procedure returns the Special product Sets for Bloomreach
							
EXEC [br].[p_ExternalJSONBloomreach_SPSAllBrands]  'SA'

Change History
--------------
Date			Author				Purpose
2021-07-15		Michael James		Created
2021-08-09		Michael James		Pricing logic tweaks
2021-08-16		Clayton Swart		Fixed category logic for SPS
2021-08-17		Clayton Swart		Added SPS on hover image and regular image
2021-08-18		Clayton Swart		Added variation-group to the variants section 
2021-08-31		Clayton Swart	 	Removed inactive skus from availability
2021-09-01		Clayton Swart	 	Fixed bud with URL - TOP 1 returning incorrect
2021-09-03		Clayton Swart		Added Productset reviews
2021-09-14		Michael James		Added is_international at set-level
2021-10-04		Clayton Swart		Added WHERE pav.Status = 1  to product attribute values
2022-03-30		Clayton Swart		Updated logic for #TEMP_Products to only select active pricing
2022-10-21		Clayton Swart		Added [value.attributes.minbrowseprice]
2023-03-16		Clayton Swart		Added all new promo and final price attributes
2024-04-29		Michael James		F23330 - Attribute load - BH,CA,SA - adding window_style, SPS attributes
2024-09-26      Marcos Sanchez      Added logic for #TEMP_Categories to attributes.category_paths level
2024-10-29		KishoreKumar		Added [beauty_concern],[bbeauty_hair_type] and [beauty_scent] in Product JSON
2024-11-02		Michael James		T29230 - Fix: Property bottom_fit cannot be generated
2024-11-25		Kishore Kumar		Added [Body Shape,Coverage,Fit,Purpose,Room,Sleeve Shape] in Variant attributes
********************************************************************************************************/

ALTER PROCEDURE [br].[p_ExternalJSONBloomreach_SPSAllBrands](@brand VARCHAR(2))
AS
    BEGIN
        SET NOCOUNT ON;
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        BEGIN TRY

        -- Declare and Initialize the local variables
        DECLARE @site VARCHAR(2)
		DECLARE @brandName VARCHAR(20)
        SELECT @site = Brandid, @brandName = BrandName
        FROM [dbo].[Brand]
        WHERE BrandCode = @brand;

				DECLARE @midnightToday datetime
		SET @midnightToday = CAST(getdate() as date)

		------marcos----
		DECLARE @midnightTmr datetime
		SET @midnightTmr = dateadd(day, 1, CAST(getdate() as date))
		-----------------

		DECLARE @debug bit
		SET @debug = 0

	    DROP TABLE IF EXISTS #TEMP_Attributes
	    DROP TABLE IF EXISTS #TEMP_ProductSets
	    DROP TABLE IF EXISTS #TEMP_Products
	    DROP TABLE IF EXISTS #TEMP_Products2
	    DROP TABLE IF EXISTS #TEMP_CategoryProducts
	    DROP TABLE IF EXISTS #TEMP_ProductSets_Pricing
		DROP TABLE IF EXISTS #TEMP_SetPromoPrices

		------marcos--------
		DROP TABLE IF EXISTS #TEMP_Categories
		SELECT [category-id] COLLATE Latin1_General_CS_AS AS [category-id], [online-flag], onlineFrom, onlineTo, isHidden
		INTO #TEMP_Categories
		FROM sfra.Category
		UPDATE #TEMP_Categories SET onlineFrom = NULL WHERE IsDate(onlineFrom) = 0
		UPDATE #TEMP_Categories SET onlineTo = NULL WHERE IsDate(onlineTo) = 0
		---------------------

		SELECT
		DISTINCT 
		SUM(inv.Quantity + inv.BackorderQuantity ) as InvAvailability, 
		MIN(CONVERT(DECIMAL(10,2),pc.SellingPrice)) as MinPrice,
		SUM(CONVERT(DECIMAL(10,2),pc.SellingPrice)) as TotalPrice,  --TODO: FIX THIS.  ONLY SHOULD ADD the TWO PRODUCTS that make up the SPS
		CASE WHEN MIN(pr2.isinternational + 0) = 0 THEN 'false' ELSE 'true' END as IsInternationalSet,  --the SPS is international ONLY if all child products are international
		ps.[product-id],
		br.BrandName,
		ps.ProductId ---marcos
		INTO #TEMP_ProductSets
		FROM sfra.SpecialProductSet ps
		INNER JOIN sfra.Product pr on ps.productID = pr.productID  
		INNER JOIN dbo.Product pr2 ON pr.ProductId = pr2.ProductId
		INNER JOIN dbo.Brand br ON pr2.BrandId = br.BrandId
		INNER JOIN dbo.Style st ON st.productID = pr2.ProductID
		INNER JOIN dbo.Size sz ON sz.StyleID = st.StyleID
		INNER JOIN dbo.Inventory inv ON sz.SizeId = inv.SizeId
		INNER JOIN dbo.Price pc ON sz.SizeId = pc.SizeID
		INNER JOIN dbo.Classification cl ON pr2.ClassificationId = cl.ClassificationId
		OUTER APPLY (SELECT SUM(inv1.Quantity + inv1.BackorderQuantity) AS VG1_Inventory
				    FROM sfra.SpecialProductSet ps1
				    INNER JOIN dbo.Style st1 ON st1.ColorId = ps1.ColorId				   
				    INNER JOIN dbo.Size sz1 ON st1.StyleId = sz1.StyleId
				    INNER JOIN dbo.Inventory inv1 ON sz1.SizeId = inv1.SizeId
				    WHERE sz1.Status = 1 AND ps1.RowNumber = 1 AND ps1.[product-id] = ps.[product-id]) vg1	
		OUTER APPLY (SELECT SUM(inv2.Quantity + inv2.BackorderQuantity) AS VG2_Inventory
				    FROM sfra.SpecialProductSet ps2
				    INNER JOIN dbo.Style st2 ON st2.ColorId = ps2.ColorId				   
				    INNER JOIN dbo.Size sz2 ON st2.StyleId = sz2.StyleId
				    INNER JOIN dbo.Inventory inv2 ON sz2.SizeId = inv2.SizeId
				    WHERE sz2.Status = 1 AND ps2.RowNumber = 2 AND ps2.[product-id] = ps.[product-id]) vg2		
		--WHERE br.BrandCode = @brand
		WHERE pr2.Status = 1 AND vg1.VG1_Inventory > 0 AND vg2.VG2_Inventory > 0
		GROUP BY ps.[product-id], br.BrandName, ps.ProductId --marcos
		HAVING SUM(inv.Quantity + inv.BackorderQuantity) > 0

		SELECT 
		--TOP 100 
		SUM(inv.Quantity + inv.BackorderQuantity ) as InvAvailability, 
		MIN(CONVERT(DECIMAL(10,2),pc.SellingPrice)) as MinPrice,
		MAX(CONVERT(DECIMAL(10,2),pc.SellingPrice)) as MaxPrice,
		ps."product-id" as SpecialProductSetID, 
		pr."product-id", COALESCE(cp."Category-Id", cp2."Category-Id") as PrimaryCategory,  pr.ProductId, pr.Brand, ps.variationGroup
		INTO #TEMP_Products
		FROM sfra.SpecialProductSet ps
		INNER JOIN sfra.Product pr ON pr.ProductId = ps.ProductId 
		INNER JOIN dbo.Product pr2 ON ps.ProductId = pr2.ProductId
		INNER JOIN dbo.Brand br ON pr2.BrandId = br.BrandId
		INNER JOIN dbo.Style st ON st.productID = pr2.ProductID AND st.ColorId = ps.ColorId
		INNER JOIN dbo.Size sz ON sz.StyleID = st.StyleID
		INNER JOIN dbo.Inventory inv ON sz.SizeId = inv.SizeId
		INNER JOIN dbo.Price pc ON sz.SizeId = pc.SizeID
		INNER JOIN dbo.Classification cl ON pr2.ClassificationId = cl.ClassificationId
		LEFT JOIN sfra.CategoryProduct cp ON pr.[product-id] = cp.[product-id] AND cp.SiteId = br.BrandCode AND cp.[primary-category] != ''
		LEFT JOIN sfra.CategoryProduct cp2 ON pr.[product-id] = cp2.[product-id] AND cp2.[primary-category] != ''
		--WHERE pr2.BrandId = @site
		WHERE pr2.Status = 1 AND sz.Status = 1 AND pc.Status = 1		
		GROUP BY ps."product-id", pr."product-id", COALESCE(cp."Category-Id", cp2."Category-Id"),  pr.ProductId, pr.Brand, ps.variationGroup
		HAVING SUM(inv.Quantity + inv.BackorderQuantity) > 0

		--RETURN

		SELECT SUM(MinPrice) as SalePrice, SpecialProductSetID
		INTO #TEMP_ProductSets_Pricing
		FROM #TEMP_Products
		GROUP BY SpecialProductSetID

		SELECT DISTINCT [product-id], listPrice, salePrice
		, IIF(SUBSTRING(listPrice, 0, charindex('-', listPrice, 0)) = '',TRY_CAST(listPrice AS MONEY), TRY_CAST(SUBSTRING(listPrice, 0, charindex('-', listPrice, 0)) AS MONEY)) ListPriceLow
		, IIF(listPrice LIKE '%-%',TRY_CAST(right(listPrice, charindex('-', reverse(listPrice)) - 1)AS MONEY),TRY_CAST(listPrice AS MONEY)) ListPricehigh
		, IIF(SUBSTRING(salePrice, 0, charindex('-', salePrice, 0)) = '',TRY_CAST(salePrice AS MONEY), TRY_CAST(SUBSTRING(salePrice, 0, charindex('-', salePrice, 0)) AS MONEY)) SalePriceLow
		, IIF(salePrice LIKE '%-%',TRY_CAST(right(salePrice, charindex('-', reverse(salePrice)) - 1)AS MONEY),TRY_CAST(salePrice AS MONEY)) SalePricehigh
		INTO #TEMP_SetPromoPrices
		FROM sfra.SpecialProductSet 

		CREATE INDEX IXNC_SetPromoPrices ON #TEMP_SetPromoPrices([product-id]);
		CREATE INDEX IXNC_Sets ON #TEMP_ProductSets ([product-id]);
		

		/* -- save for later when we want to send final sale prices per product
		;WITH PS AS (
		SELECT DISTINCT ps."product-id" FROM sfra.SpecialProductSet ps
		)
		SELECT ps."product-id", setprice.*
		INTO #TEMP_SetPromoPrices
		FROM ps ps
		CROSS APPLY(SELECT MIN(sf.minBrwPrice) AS minBrwPrice, MAX(sf.maxBrwPrice) AS maxBrwPrice,
		MIN(sf.minClrPrice) AS minClrPrice, MAX(sf.maxClrPrice) AS maxClrPrice,
		MIN(sf.minFSPrice) AS minFSPrice, MAX(sf.maxFSPrice) AS maxFSPrice,
		MIN(pr.minBrwPrice) AS minBrwPriceBR, MAX(pr.maxBrwPrice) AS maxBrwPriceBR,
		MIN(pr.minClrPrice) AS minClrPriceBR, MAX(pr.maxClrPrice) AS maxClrPriceBR,
		MIN(pr.minFSPrice) AS minFSPriceBR, MAX(pr.maxFSPrice) AS maxFSPriceBR,
		MIN(pr.minBrwListPrice) AS minBrwListPriceBR, MAX(pr.maxBrwListPrice) AS maxBrwListPriceBR,
		MIN(pr.minClrListPrice) AS minClListPriceBR, MAX(pr.maxClrListPrice) AS maxClrListPriceBR,
		MIN(pr.minFSListPrice) AS minFSListPriceBR, MAX(pr.maxFSListPrice) AS maxFSListPriceBR
		FROM br.ProductPrice pr
		LEFT JOIN sfra.FinalPricePromo sf ON pr.Productid = sf.ProductId
		WHERE pr.Productid IN ( SELECT  ps1.Productid
								FROM sfra.SpecialProductSet ps1 
								WHERE ps1."product-id" = ps."product-id")) setprice
		
		*/
		--SELECT DISTINCT p.ProductID, cp.SiteId
		SELECT DISTINCT p.[product-id], p.ProductID, cp.SiteId
	    INTO #TEMP_CategoryProducts
	    FROM sfra.CategoryProduct cp
		INNER JOIN sfra.Product p ON cp.[product-id] = p.[product-id]
      		
		SELECT * INTO #TEMP_Attributes FROM
		(
		 SELECT pav.ProductId, att.BloomreachAttributeName, 
		 STRING_AGG(COALESCE(av.DisplayValue, av.AttributeValue),'|') as AttributeValue
         FROM dbo.ProductAttributeValue pav
		 INNER JOIN dbo.Attribute att ON pav.AttributeId = att.AttributeId
		 INNER JOIN dbo.AttributeValue av ON pav.AttributeValueID = av.AttributeValueID
	    WHERE pav.Status = 1 			
         GROUP BY pav.productid, att.BloomreachAttributeName			
		) attr
		PIVOT
		(
    		MAX(AttributeValue)
    		FOR BloomreachAttributeName in ([application],
						[beauty_concern],
						[beauty_hair_type],
						[beauty_scent],
						[body_shape],
						[bottom_fit],
						[bra_lining],
						[bra_support_level],
						[capacity],
						[care],
						[coat_weight],
						[comfort_level],
						[construction],
						[coverage],
						[fabric],
						[fabric_/_material],
						[features],
						[fill_material],
						[fit],
						[heel_height],
						[height],
						[included],
						[item_type],
						[length],
						[light_count],
						[light_filtration],
						[lighting_color],
						[lighting_type],
						[material],
						[multi_packs],
						[neckline],
						[occasion],
						[pillow_type],
						[product_thickness],
						[purpose],
						[rod-type],
						[room],
						[sets],
						[shape],
						[sheet_type],
						[shorts_inseam],
						[sleep_position],
						[sleeve_length],
						[sleeve_shape],
						[style],
						[swim_coverage],
						[theme],
						[thread_count],
						[towel-type],
						[voltage],
						[weight],
						[width],
						[window_style],
						[wreath_size])
		) AS pivoted

		SELECT STRING_AGG(s2.MFItemID, '|') as MFItemID, s2.ProductID
		INTO #TEMP_Products2
		FROM 
		(SELECT distinct s.MFItemID, s.ProductID
		from Style s
		INNER JOIN dbo.Product p on s.ProductID = p.ProductID
		--WHERE p.BrandId = @site
		AND p.Status = 1) s2
		GROUP by s2.ProductID

		CREATE NONCLUSTERED INDEX IXNC_Attributes ON #TEMP_Attributes ([ProductId])
		INCLUDE ([application],[beauty_concern],[beauty_hair_type],[beauty_scent],[bottom_fit],[bra_lining],[bra_support_level],[capacity],[care],[coat_weight],[comfort_level],[construction],[fabric],[fabric_/_material],[features],[fill_material],[heel_height],[height],[included],[item_type],[length],[light_count],[light_filtration],[lighting_color],[lighting_type],[material],[multi_packs],[neckline],[occasion],[pillow_type],[product_thickness],[rod-type],[sets],[shape],[sheet_type],[shorts_inseam],[sleep_position],[sleeve_length],[style],[swim_coverage],[theme],[thread_count],[towel-type],[voltage],[weight],[width],[window_style],[wreath_size])
		CREATE NONCLUSTERED INDEX IXNC_Product2 ON #TEMP_Products2 ([ProductID]);


		DECLARE @JSON1 NVARCHAR(MAX) 
		DECLARE @JSON NVARCHAR(MAX)  =
		(
		SELECT 
		DISTINCT 
		--top 10000  --only 747 distinct SPS product-ids in test.  only 544 rows when i actually generate the file...
		'add' AS [op],
		'/products/' + CONVERT(varchar(20), ps.[product-id]) as [path],		
		'Swimsuits for All' as [value.attributes.brand],
		ps.[display-name] as [value.attributes.title],
		CONVERT(bit, IIF(ps1.InvAvailability > 0, 1, 0)) as [value.attributes.availability],		
		ps1.IsInternationalSet as [value.attributes.is_international], 
		spsp.SalePrice as [value.attributes.price],		
		spsp.SalePrice as [value.attributes.minbrowseprice], 
		spr.SalePriceLow AS [value.attributes.minBrwPrice], 
		spr.SalePricehigh AS [value.attributes.maxBrwPrice], 
		spr.SalePriceLow AS [value.attributes.minClrPrice], 
		spr.SalePricehigh AS [value.attributes.maxClrPrice], 
		spr.SalePriceLow AS [value.attributes.minFSPrice], 
		spr.SalePricehigh AS [value.attributes.maxFSPrice], 
		spr.listPrice AS [value.attributes.brwListPrice], 
		spr.salePrice AS [value.attributes.brwSalePrice], 
		spr.listPrice AS [value.attributes.clrListPrice], 
		spr.salePrice AS [value.attributes.clrSalePrice], 
		spr.listPrice AS [value.attributes.fsListPrice], 
		spr.salePrice AS [value.attributes.fsSalePrice],
			'' AS [value.attributes.minBrwVariants],  
			'' AS [value.attributes.maxBrwVariants], 
			'' AS [value.attributes.minPriceVariants],  
			'' AS [value.attributes.maxPriceVariants], 
			'' AS [value.attributes.minFSPriceVariants], 
			'' AS [value.attributes.maxFSPriceVariants], 
			'' AS [value.attributes.backOrderMinVariantsBrw],  
			'' AS [value.attributes.backOrderMaxVariantsBrw], 
			'' AS [value.attributes.backOrderMinVariants], 
			'' AS [value.attributes.backOrderMaxVariants], 
			'' as [value.attributes.brwPromoID],
			'' as [value.attributes.clrPromoID],
			'' as [value.attributes.fsPromoID],
			'' as [value.attributes.brwssVariantID],
			'' as [value.attributes.clrssVariantID],
			'' as [value.attributes.fsssVariantID],
			'' as [value.attributes.brwPLPSS],
			'' as [value.attributes.clrPLPSS],
			'' as [value.attributes.fsPLPSS],
		CONVERT(varchar(20),psr.ReviewCount) AS [value.attributes.review_count], 
		CONVERT(varchar(20),psr.AverageRating) AS [value.attributes.review_average], 
		ps.url as [value.attributes.url],
		img.[image-path] AS [value.attributes.thumb_image],
		hoverImg.SFCCImageURL AS [value.attributes.onhover_image],
		'Y' as [value.attributes.is_special_productset],	
		CASE WHEN attr2.[item_type] IS NULL THEN NULL WHEN CHARINDEX ('|', attr2.[item_type]) = 0 THEN CONCAT('"',replace(attr2.[item_type],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr2.[item_type],'"','\"'), '|', '","'),'"]'))) END as [value.attributes.item_type],
		
		(
			SELECT 
			--TOP 1000
			p1.[variationGroup] as [@productid],
			pr.Title AS [attributes1.title],
			pr.Description AS [attributes1.description],
			b.BrandName AS [attributes1.brand], 
			'N' as [attributes1.is_marketplace_item],
		    CONVERT(bit, IIF(p1.InvAvailability > 0, 1, 0)) as [attributes1.availability],
			IIF(pr.isinternational = 1, 'true', 'false') as [attributes1.is_international],
			IIF(pr.BrandId = 11, 'Mens', 'Womens') as [attributes1.gender], 
			pr.PCMBrand as [attributes1.brand_label], 
			CONVERT(varchar(20), pr.CustomerReviewCount) AS [attributes1.review_count], 
			pr.CustomerReviewAverage AS [attributes1.review_average], 
			url.url as [attributes1.url],
			p1.MaxPrice as [attributes1.price],
			p1.MinPrice as [attributes1.sale_price],	
			CASE WHEN [application] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[application]) = 0 THEN CONCAT('"',replace(attr.[application],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[application],'"','\"'), '|', '","'),'"]'))) END as [attributes1.application],
			CASE WHEN [beauty_concern] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[beauty_concern]) = 0 THEN CONCAT('"',replace(attr.[beauty_concern],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[beauty_concern],'"','\"'), '|', '","'),'"]'))) END as [attributes1.beauty_concern],
			CASE WHEN [beauty_hair_type] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[beauty_hair_type]) = 0 THEN CONCAT('"',replace(attr.[beauty_hair_type],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[beauty_hair_type],'"','\"'), '|', '","'),'"]'))) END as [attributes1.beauty_hair_type],
			CASE WHEN [beauty_scent] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[beauty_scent]) = 0 THEN CONCAT('"',replace(attr.[beauty_scent],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[beauty_scent],'"','\"'), '|', '","'),'"]'))) END as [attributes1.beauty_scent],
			CASE WHEN [body_shape] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[body_shape]) = 0 THEN CONCAT('"',replace(attr.[body_shape],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[body_shape],'"','\"'), '|', '","'),'"]'))) END as [attributes1.body_shape],			
			CASE WHEN [bottom_fit] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[bottom_fit]) = 0 THEN CONCAT('"',replace(attr.[bottom_fit],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[bottom_fit],'"','\"'), '|', '","'),'"]'))) END as [attributes1.bottom_fit],
			CASE WHEN [bra_lining] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[bra_lining]) = 0 THEN CONCAT('"',replace(attr.[bra_lining],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[bra_lining],'"','\"'), '|', '","'),'"]'))) END as [attributes1.bra_lining],
			CASE WHEN [bra_support_level] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[bra_support_level]) = 0 THEN CONCAT('"',replace(attr.[bra_support_level],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[bra_support_level],'"','\"'), '|', '","'),'"]'))) END as [attributes1.bra_support_level],
			CASE WHEN [capacity] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[capacity]) = 0 THEN CONCAT('"',replace(attr.[capacity],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[capacity],'"','\"'), '|', '","'),'"]'))) END as [attributes1.capacity_],
			CASE WHEN [care] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[care]) = 0 THEN CONCAT('"',replace(attr.[care],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[care],'"','\"'), '|', '","'),'"]'))) END as [attributes1.care],
			CASE WHEN [coat_weight] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[coat_weight]) = 0 THEN CONCAT('"',replace(attr.[coat_weight],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[coat_weight],'"','\"'), '|', '","'),'"]'))) END as [attributes1.coat_weight],
			CASE WHEN [comfort_level] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[comfort_level]) = 0 THEN CONCAT('"',replace(attr.[comfort_level],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[comfort_level],'"','\"'), '|', '","'),'"]'))) END as [attributes1.comfort_level],
			CASE WHEN [construction] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[construction]) = 0 THEN CONCAT('"',replace(attr.[construction],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[construction],'"','\"'), '|', '","'),'"]'))) END as [attributes1.construction],
			CASE WHEN [coverage] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[coverage]) = 0 THEN CONCAT('"',replace(attr.[coverage],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[coverage],'"','\"'), '|', '","'),'"]'))) END as [attributes1.coverage],			
			CASE WHEN [fabric] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[fabric]) = 0 THEN CONCAT('"',replace(attr.[fabric],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[fabric],'"','\"'), '|', '","'),'"]'))) END as [attributes1.fabric],
			CASE WHEN [fabric_/_material] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[fabric_/_material]) = 0 THEN CONCAT('"',replace(attr.[fabric_/_material],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[fabric_/_material],'"','\"'), '|', '","'),'"]'))) END as [attributes1.fabric_material],
			CASE WHEN [features] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[features]) = 0 THEN CONCAT('"',replace(attr.[features],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[features],'"','\"'), '|', '","'),'"]'))) END as [attributes1.features],
			CASE WHEN [fill_material] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[fill_material]) = 0 THEN CONCAT('"',replace(attr.[fill_material],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[fill_material],'"','\"'), '|', '","'),'"]'))) END as [attributes1.fill_material],
			CASE WHEN [fit] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[fit]) = 0 THEN CONCAT('"',replace(attr.[fit],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[fit],'"','\"'), '|', '","'),'"]'))) END as [attributes1.fit],			
			CASE WHEN [heel_height] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[heel_height]) = 0 THEN CONCAT('"',replace(attr.[heel_height],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[heel_height],'"','\"'), '|', '","'),'"]'))) END as [attributes1.heel_height],
			CASE WHEN [height] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[height]) = 0 THEN CONCAT('"',replace(attr.[height],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[height],'"','\"'), '|', '","'),'"]'))) END as [attributes1.height_],
			CASE WHEN [included] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[included]) = 0 THEN CONCAT('"',replace(attr.[included],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[included],'"','\"'), '|', '","'),'"]'))) END as [attributes1.included],
			CASE WHEN attr.[item_type] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[item_type]) = 0 THEN CONCAT('"',replace(attr.[item_type],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[item_type],'"','\"'), '|', '","'),'"]'))) END as [attributes1.item_type],
			CASE WHEN [length] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[length]) = 0 THEN CONCAT('"',replace(attr.[length],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[length],'"','\"'), '|', '","'),'"]'))) END as [attributes1.length],
			CASE WHEN [light_count] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[light_count]) = 0 THEN CONCAT('"',replace(attr.[light_count],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[light_count],'"','\"'), '|', '","'),'"]'))) END as [attributes1.light_count],
			CASE WHEN [light_filtration] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[light_filtration]) = 0 THEN CONCAT('"',replace(attr.[light_filtration],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[light_filtration],'"','\"'), '|', '","'),'"]'))) END as [attributes1.light_filtration],
			CASE WHEN [lighting_color] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[lighting_color]) = 0 THEN CONCAT('"',replace(attr.[lighting_color],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[lighting_color],'"','\"'), '|', '","'),'"]'))) END as [attributes1.lighting_color],
			CASE WHEN [lighting_type] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[lighting_type]) = 0 THEN CONCAT('"',replace(attr.[lighting_type],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[lighting_type],'"','\"'), '|', '","'),'"]'))) END as [attributes1.lighting_type],
			CASE WHEN [material] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[material]) = 0 THEN CONCAT('"',replace(attr.[material],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[material],'"','\"'), '|', '","'),'"]'))) END as [attributes1.material],
			CASE WHEN [multi_packs] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[multi_packs]) = 0 THEN CONCAT('"',replace(attr.[multi_packs],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[multi_packs],'"','\"'), '|', '","'),'"]'))) END as [attributes1.multi_packs],
			CASE WHEN [neckline] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[neckline]) = 0 THEN CONCAT('"',replace(attr.[neckline],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[neckline],'"','\"'), '|', '","'),'"]'))) END as [attributes1.neckline],
			CASE WHEN [occasion] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[occasion]) = 0 THEN CONCAT('"',replace(attr.[occasion],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[occasion],'"','\"'), '|', '","'),'"]'))) END as [attributes1.occasion],
			CASE WHEN [pillow_type] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[pillow_type]) = 0 THEN CONCAT('"',replace(attr.[pillow_type],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[pillow_type],'"','\"'), '|', '","'),'"]'))) END as [attributes1.pillow_type],
			CASE WHEN [product_thickness] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[product_thickness]) = 0 THEN CONCAT('"',replace(attr.[product_thickness],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[product_thickness],'"','\"'), '|', '","'),'"]'))) END as [attributes1.product_thickness],
			CASE WHEN [purpose] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[purpose]) = 0 THEN CONCAT('"',replace(attr.[purpose],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[purpose],'"','\"'), '|', '","'),'"]'))) END as [attributes1.purpose],			
			CASE WHEN [rod-type] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[rod-type]) = 0 THEN CONCAT('"',replace(attr.[rod-type],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[rod-type],'"','\"'), '|', '","'),'"]'))) END as [attributes1.rod_type],
			CASE WHEN [room] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[room]) = 0 THEN CONCAT('"',replace(attr.[room],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[room],'"','\"'), '|', '","'),'"]'))) END as [attributes1.room],			
			CASE WHEN [sets] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[sets]) = 0 THEN CONCAT('"',replace(attr.[sets],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[sets],'"','\"'), '|', '","'),'"]'))) END as [attributes1.sets],
			CASE WHEN [shape] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[shape]) = 0 THEN CONCAT('"',replace(attr.[shape],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[shape],'"','\"'), '|', '","'),'"]'))) END as [attributes1.shape],
			CASE WHEN [sheet_type] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[sheet_type]) = 0 THEN CONCAT('"',replace(attr.[sheet_type],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[sheet_type],'"','\"'), '|', '","'),'"]'))) END as [attributes1.sheet_type],
			CASE WHEN [shorts_inseam] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[shorts_inseam]) = 0 THEN CONCAT('"',replace(attr.[shorts_inseam],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[shorts_inseam],'"','\"'), '|', '","'),'"]'))) END as [attributes1.shorts_inseam],
			CASE WHEN [sleep_position] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[sleep_position]) = 0 THEN CONCAT('"',replace(attr.[sleep_position],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[sleep_position],'"','\"'), '|', '","'),'"]'))) END as [attributes1.sleep_position],
			CASE WHEN [sleeve_length] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[sleeve_length]) = 0 THEN CONCAT('"',replace(attr.[sleeve_length],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[sleeve_length],'"','\"'), '|', '","'),'"]'))) END as [attributes1.sleeve_length],
			CASE WHEN [sleeve_shape] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[sleeve_shape]) = 0 THEN CONCAT('"',replace(attr.[sleeve_shape],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[sleeve_shape],'"','\"'), '|', '","'),'"]'))) END as [attributes1.sleeve_shape],			
			CASE WHEN [style] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[style]) = 0 THEN CONCAT('"',replace(attr.[style],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[style],'"','\"'), '|', '","'),'"]'))) END as [attributes1.style],
			CASE WHEN [swim_coverage] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[swim_coverage]) = 0 THEN CONCAT('"',replace(attr.[swim_coverage],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[swim_coverage],'"','\"'), '|', '","'),'"]'))) END as [attributes1.swim_coverage],
			CASE WHEN [theme] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[theme]) = 0 THEN CONCAT('"',replace(attr.[theme],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[theme],'"','\"'), '|', '","'),'"]'))) END as [attributes1.theme],
			CASE WHEN [thread_count] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[thread_count]) = 0 THEN CONCAT('"',replace(attr.[thread_count],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[thread_count],'"','\"'), '|', '","'),'"]'))) END as [attributes1.thread_count],
			CASE WHEN [towel-type] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[towel-type]) = 0 THEN CONCAT('"',replace(attr.[towel-type],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[towel-type],'"','\"'), '|', '","'),'"]'))) END as [attributes1.towel-type],
			CASE WHEN [voltage] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[voltage]) = 0 THEN CONCAT('"',replace(attr.[voltage],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[voltage],'"','\"'), '|', '","'),'"]'))) END as [attributes1.voltage],
			CASE WHEN [weight] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[weight]) = 0 THEN CONCAT('"',replace(attr.[weight],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[weight],'"','\"'), '|', '","'),'"]'))) END as [attributes1.weight],
			CASE WHEN [width] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[width]) = 0 THEN CONCAT('"',replace(attr.[width],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[width],'"','\"'), '|', '","'),'"]'))) END as [attributes1.width_],
			CASE WHEN [window_style] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[window_style]) = 0 THEN CONCAT('"',replace(attr.[window_style],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[window_style],'"','\"'), '|', '","'),'"]'))) END as [attributes1.window_style],
			CASE WHEN [wreath_size] IS NULL THEN NULL WHEN CHARINDEX ('|', attr.[wreath_size]) = 0 THEN CONCAT('"',replace(attr.[wreath_size],'"','\"'),'"') ELSE JSON_QUERY((SELECT CONCAT('["',REPLACE(replace(attr.[wreath_size],'"','\"'), '|', '","'),'"]'))) END as [attributes1.wreath_size]
			
			FROM #TEMP_Products p1
			INNER JOIN #TEMP_Products2 p2 ON p1.productID = p2.productID
			INNER JOIN sfra.SpecialProductSet ps2 ON p1.[productID] = ps2.[productID] AND ps2.[product-id] = ps1.[product-id] AND p1.SpecialProductSetID = ps2.[product-id]
			INNER JOIN dbo.Product pr ON p1.productID = pr.productID
			INNER JOIN dbo.Brand b ON pr.BrandID = b.BrandID
			INNER JOIN br.ProductPrice br ON p1.ProductId = br.ProductId
			LEFT JOIN sfra.FinalPricePromo pro ON p1.ProductId = pro.ProductId AND pro.DateCreated >= @midnightToday 
			INNER JOIN dbo.Classification cl ON pr.ClassificationId = cl.ClassificationId
			CROSS APPLY
			(SELECT 
			--TOP 1000
			st.ProductId,
					MAX(sz.WasPrice) AS item_listpricehigh,
					MIN(sz.WasPrice) AS item_listpricelow,
					MAX(pc.SellingPrice) AS item_salepricehigh,
					MIN(pc.SellingPrice) AS item_salepricelow,
					SUM(inv.Quantity) AS inventory
				FROM dbo.Price pc
				INNER JOIN dbo.Size sz ON sz.SizeId = pc.SizeId
				INNER JOIN dbo.Inventory inv ON sz.SizeId = inv.SizeId
				INNER JOIN dbo.Style st ON st.StyleId = sz.StyleId
				WHERE pr.ProductId = st.ProductId  AND pc.Status = 1 AND sz.Status = 1 AND st.Status = 1 AND (inv.Quantity + inv.BackOrderQuantity > 0)
				GROUP BY st.ProductId
			) pricing
			LEFT JOIN #TEMP_Attributes attr on pr.ProductId = attr.ProductId
			CROSS APPLY (SELECT TOP 1 sp."product-id", sp.productID FROM sfra.Product sp WHERE sp."product-id" = p1."product-id") sfp		
			OUTER APPLY sfra.fn_GetProductUrl(sfp."product-id", b.BrandCode) AS url					
			OUTER APPLY br.fn_GetProductMainImage(sfp."product-id", b.BrandCode) img
			OUTER APPLY sfra.fn_GetProductOnHoverImage(pr.ProductID, b.BrandCode) hoverImg
		--	WHERE pr.BrandId = @site
			FOR JSON PATH
		) AS [value.variants],
		
		(SELECT  
			cp.siteid AS "@brandcode",
			"attributes.category_paths" = (	
							/*SELECT  'test' as testfield,
								(SELECT catroot."category-id"  AS 'id', catroot."display-name" AS 'name'					   
								FROM sfra.CategoryProduct cp2				
								INNER JOIN sfra.Category cat2 ON cp2.[category-id] = cat2.[category-id]
								CROSS APPLY sfra.fn_GetCategoryList(cp1."category-id", cp.SiteId) catroot
								WHERE  cp2.SiteId = cp1.SiteId AND cp2.[product-id] = cte.[product-id] AND cp2.[category-id] = cp1.[category-id]
								AND ISNULL(cat2.[ishidden], 0) = 0
								FOR JSON PATH) h
							FROM sfra.CategoryProduct cp1
   						    INNER JOIN sfra.Category cat1 ON cp1.[category-id] = cat1.[category-id]
							WHERE  cp1.SiteId = cp.SiteId AND cp1.[product-id] = cte.[product-id]
  						    AND ISNULL(cat1.[ishidden], 0) = 0
							ORDER BY cp1."primary-category" DESC
							FOR JSON PATH*/

							--------marcos---------------
							SELECT  'test' as testfield,
								(SELECT catroot."category-id"  AS 'id', catroot."display-name" AS 'name'					   
								FROM sfra.CategoryProduct cp2				
								INNER JOIN #TEMP_Categories cat2 ON cp2.[category-id] = cat2.[category-id] 
								CROSS APPLY sfra.fn_GetCategoryList(cp1."category-id", cp.SiteId) catroot
								WHERE  cp2.SiteId = cp1.SiteId AND cp2.[product-id] = cte.[product-id] AND cp2.[category-id] = cp1.[category-id]
								AND ISNULL(cat2.[ishidden], 0) = 0 AND ISNULL(cat2.[online-flag], 'false') = 'true'
								AND 
								(  
									(cat2.onlinefrom IS NULL AND cat2.onlineto IS NULL)
									OR
									(cat2.onlinefrom IS NULL AND @midnightTmr <= cat2.onlineTo)
									OR
									(cat2.onlinefrom < @midnightTmr and cat2.onlineTo is NULL)
									OR
									(cat2.onlinefrom < @midnightTmr and @midnightTmr <= cat2.onlineTo)
									)
								FOR JSON PATH) h
							FROM sfra.CategoryProduct cp1
   						    INNER JOIN sfra.Category c1 ON cp1.[category-id] = c1.[category-id]
							INNER JOIN #TEMP_Categories cat1 ON cp1.[category-id] = cat1.[category-id] 
							WHERE  cp1.SiteId = cp.SiteId AND cp1.[product-id] = cte.[product-id]
  						    AND ISNULL(cat1.[ishidden], 0) = 0 AND ISNULL(cat1.[online-flag], 'false') = 'true'
							AND 
							(  
								(cat1.onlinefrom IS NULL AND cat1.onlineto IS NULL)
								OR
								(cat1.onlinefrom IS NULL AND @midnightTmr <= cat1.onlineTo) 
								OR
								(cat1.onlinefrom < @midnightTmr and cat1.onlineTo is NULL) 
								OR
								(cat1.onlinefrom < @midnightTmr and @midnightTmr <= cat1.onlineTo)
							)
							ORDER BY cp1."primary-category" DESC
							FOR JSON PATH
							---------------------------------------
			),
			-- cp.siteid AS "attributes.brand",
			 url.url AS "attributes.url"
			 FROM #TEMP_ProductSets cte
			 CROSS APPLY (SELECT DISTINCT cp.SiteId FROM sfra.CategoryProduct cp WHERE cp.[product-id] = cte.[product-id]) cp
			 CROSS APPLY sfra.fn_GetSpecialProductSetUrl(cte.[product-id], cp.SiteId) url
			 WHERE cte.[product-id] = ps.[product-id] 
			 ORDER BY cp.SiteId
			 FOR JSON PATH
			) AS [value.views]	
		FROM #TEMP_ProductSets ps1
		CROSS APPLY (SELECT TOP 1 ps.* FROM sfra.SpecialProductSet ps WHERE ps1.[product-id] = ps.[product-id]) ps
		INNER JOIN #TEMP_ProductSets_Pricing spsp ON ps.[product-id] = spsp.SpecialProductSetID
		CROSS APPLY (SELECT TOP 1 sp."product-id", sp.ProductID FROM sfra.Product sp WHERE sp.ProductID = ps.ProductID) sfp
		LEFT JOIN #TEMP_Attributes attr on sfp.productID = attr.ProductId
		LEFT JOIN #TEMP_SetPromoPrices spr ON spr.[product-id] = ps1.[product-id]
		OUTER APPLY br.fn_GetProductSetMainImage(ps.[product-id], @brand) img
		OUTER APPLY sfra.fn_GetProductSetOnHoverImage(ps.[product-id], @brand) hoverImg
		LEFT JOIN FeedProcessor.turnto.ProductSetReviews psr ON ps.uberSetID = psr.ProductSetId
		LEFT JOIN br.SPSAttributes attr2 on ps1.[product-id] = attr2.SPSId
		WHERE ps.searchableflag = 1 AND ps.onlineflag = 1 AND ps.availableflag = 1
		--ORDER BY ps1.[product-id]
		FOR JSON PATH)

	
		SELECT @JSON1 = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@JSON,'[{"@productid":','{'),'{"@productid":',''),'[{"@brandcode":','{'),'{"@brandcode":',''),',"attributes"',':{ "attributes"'),'","attributes1"','":{ "attributes"'),'}}]}}','}}}}}'),'}}],"views"','}}},"views"'),'"category_paths":[{"testfield":"test","h":[','"category_paths":[['),'},{"testfield":"test","h":',','),'}]}],"url"','}]],"url"')
		SELECT @JSON1

	    DROP TABLE IF EXISTS #TEMP_Attributes
	    DROP TABLE IF EXISTS #TEMP_ProductSets
	    DROP TABLE IF EXISTS #TEMP_Products
	    DROP TABLE IF EXISTS #TEMP_Products2
	    DROP TABLE IF EXISTS #TEMP_CategoryProducts
	    DROP TABLE IF EXISTS #TEMP_ProductSets_Pricing
		DROP TABLE IF EXISTS #TEMP_SetPromoPrices		
             
        END TRY
        BEGIN CATCH
            DECLARE @Errormessage VARCHAR(MAX);
            DECLARE @Erroredobject VARCHAR(255);
            DECLARE @Errortype VARCHAR(50);
            SELECT @Errormessage = 'ERROR: '+CONVERT(VARCHAR(10), ERROR_NUMBER())+' SEVERITY: '+CONVERT(VARCHAR(10), ERROR_SEVERITY())+' STATE: '+CONVERT(VARCHAR(10), ERROR_STATE())+' ERRORPROCEDURE: '+CONVERT(VARCHAR(100), ERROR_PROCEDURE())+' ERRORLINE: '+CONVERT(VARCHAR(10), ERROR_LINE())+' ERRORMESSAGE: '+CONVERT(VARCHAR(1000), ERROR_MESSAGE());
            SELECT @Erroredobject = CONVERT(VARCHAR(100), ERROR_PROCEDURE());
            SELECT @Errortype = CONVERT(VARCHAR(10), ERROR_NUMBER());

            -- Call SP to Write To Error Log Table
            EXEC [dbo].[p_inserterrorlog]
                @Erroredobject,
                @Errortype,
                @Errormessage;
            PRINT @Errormessage;
		RAISERROR (@errormessage, 16, 1);
        END CATCH;
    END;
