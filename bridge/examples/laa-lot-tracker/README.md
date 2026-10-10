# FigJam board recreation

A private FigJam board was exported to PDF and recreated in regular Freeform through the bridge's import path (`fitAfterPaste`, up to 1,000 encoded objects). The PDF's vector paths and searchable text were extracted locally, with text lines matched to their outlines and replaced by editable text. Verification copied all 698 objects back from Freeform and checked exact text, sizes, and relative positions within 0.01 points, plus clipboard restoration.

The source export, extracted data, and proof files contain private business information and are kept locally only; they are not part of this repository. The import scripts live outside the repository as well.

Known limits of the recreation: text uses fitted system fonts; labels and background boxes are separate objects rather than grouped cards; arrows are editable vector shapes, not attached connectors; tables are rebuilt from cells and text.
