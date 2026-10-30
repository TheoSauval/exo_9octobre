-- Migration 002 : référence SKU unique par produit (idempotente)
-- Colonne NOT NULL ajoutée AVEC une valeur par défaut : les clients existants qui insèrent
-- des produits sans connaître la colonne (ancienne version de l'API, scripts de seed) continuent de fonctionner.
BEGIN;
ALTER TABLE products ADD COLUMN IF NOT EXISTS sku TEXT;
UPDATE products SET sku = 'SKU-' || lpad(id::text, 5, '0') WHERE sku IS NULL;
ALTER TABLE products ALTER COLUMN sku SET DEFAULT ('SKU-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 12)));
ALTER TABLE products ALTER COLUMN sku SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS products_sku_key ON products(sku);
COMMIT;
