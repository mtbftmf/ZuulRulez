# Chat templates (Flash-Next)

Copy these two files here from `~` on the Mac and commit them:

    cp ~/flash-next-template-original.jinja ~/flash-next-template-medium.jinja m5/templates/

- `flash-next-template-original.jinja`: stock template extracted from shard 1 (`gguf-template.py`); default effort `xhigh`.
- `flash-next-template-medium.jinja`: edited copy; line 47 replaced so the default is `medium` and `[effort:xhigh]` / `[effort:low]` in the first system message override it.

Apply with `gguf-set-template.py` (see the README's "Effort control" section). A rebuild from the original template is byte-identical to the stock shard, so these two files are the backup.
