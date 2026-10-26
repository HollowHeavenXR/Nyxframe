import { useCallback, useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { apiFetch, cachedApiFetch, prefetchApi, toQuery } from "../api.js";
import { PAGE_SIZE } from "../config.js";
import { MediaGrid } from "../components/media.jsx";
import { Notice, Page, Pager } from "../components/ui.jsx";
import { preloadMediaAssets, replaceMedia } from "../utils/media.js";

function pageSizeFor(settings) {
  const parsed = Number(settings?.items_per_page);
  if (!Number.isFinite(parsed)) return PAGE_SIZE;
  return Math.min(60, Math.max(12, Math.round(parsed)));
}

export function CategoryPage({ ctx }) {
  const { categoryId } = useParams();
  const [subcategoryId, setSubcategoryId] = useState("");
  const [page, setPage] = useState(1);
  const [items, setItems] = useState([]);
  const [hasNext, setHasNext] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const pageSize = pageSizeFor(ctx.settings);
  // Links use either the numeric id or the slug (/category/wallpapers).
  const category = ctx.lookups.categories.find((c) => String(c.id) === String(categoryId) || c.slug === categoryId);
  const subcategories = category?.subcategories || category?.children || [];

  const handleItemUpdated = useCallback((item) => setItems((rows) => replaceMedia(rows, item)), []);

  useEffect(() => {
    setSubcategoryId("");
    setPage(1);
  }, [categoryId]);

  const loadCategory = useCallback(({ background = false } = {}) => {
    if (!categoryId) return Promise.resolve();
    return (async () => {
      if (!background) { setLoading(true); setError(""); }
      try {
        const path = `/api/media${toQuery({
          category_id: categoryId,
          subcategory_id: subcategoryId,
          sort: "new",
          limit: pageSize + 1,
          offset: (page - 1) * pageSize,
        })}`;
        const data = background
          ? await apiFetch(path)
          : await cachedApiFetch(path, { ttl: 20_000, staleTtl: 3 * 60_000 });
        const rows = data.media || [];
        setItems(rows.slice(0, pageSize));
        setHasNext(rows.length > pageSize);
        preloadMediaAssets(rows, { limit: 6 });
        if (rows.length > pageSize) {
          prefetchApi(`/api/media${toQuery({ category_id: categoryId, subcategory_id: subcategoryId, sort: "new", limit: pageSize + 1, offset: page * pageSize })}`, { ttl: 30_000, staleTtl: 3 * 60_000 });
        }
      } catch (fetchError) {
        if (!background) setError(fetchError.message);
      } finally {
        if (!background) setLoading(false);
      }
    })();
  }, [categoryId, subcategoryId, page, pageSize]);

  useEffect(() => {
    loadCategory();
  }, [loadCategory]);

  return (
    <Page
      title={category?.name || "Category"}
      eyebrow="Browse"
      lede={category ? `Everything filed under ${category.name}.` : ""}
    >
      {error ? <Notice kind="error" onRetry={() => loadCategory()}>{error}</Notice> : null}
      {subcategories.length ? (
        <div className="category-chip-row">
          <button
            type="button"
            className={!subcategoryId ? "active" : ""}
            onClick={() => { setSubcategoryId(""); setPage(1); }}
          >
            All
          </button>
          {subcategories.map((sub) => (
            <button
              type="button"
              key={sub.id}
              className={String(subcategoryId) === String(sub.id) ? "active" : ""}
              onClick={() => { setSubcategoryId(sub.id); setPage(1); }}
            >
              {sub.name}
            </button>
          ))}
        </div>
      ) : null}
      <MediaGrid ctx={ctx} items={items} loading={loading} emptyTitle="No posts in this category yet" onItemUpdated={handleItemUpdated} onOpen={ctx.openLightbox} />
      <Pager page={page} hasNext={hasNext} loading={loading} onPage={setPage} />
    </Page>
  );
}
