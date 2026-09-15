# Rebuilds RFDETRNano.mlpackage, the person detector PlayerTracker can use for
# re-acquisition (PlayerTracker.useDetector, off as of 2026-09-15).
#
#   python3 -m venv .venv && .venv/bin/pip install rfdetr coremltools
#   .venv/bin/python make_model.py
#
# RF-DETR Nano is Apache-2.0 (the XLarge sizes are not — do not swap them in).
# Weights come from Roboflow's own hosting via the rfdetr package.
# 6-bit per-tensor palettization: 52 MB -> 20 MB and matched all 94 FP16
# detections on 21 court-side frames; 4-bit returned nothing, grouped 4-bit
# needs iOS 18. To ship it, copy the output into ios/Ribatto/Engine/ (the
# file-system-synchronized group bundles it) and add the Apache-2.0 notice to
# LicensesView.
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as oc
from rfdetr import RFDETRNano

out = Path("export")
out.mkdir(exist_ok=True)
fp16 = RFDETRNano().export(format="coreml", output_dir=str(out), coreml_precision="float16")
model = ct.models.MLModel(str(fp16), skip_model_load=True)
config = oc.OptimizationConfig(global_config=oc.OpPalettizerConfig(
    mode="kmeans", nbits=6, granularity="per_tensor", weight_threshold=2048))
oc.palettize_weights(model, config).save("RFDETRNano.mlpackage")
print("wrote RFDETRNano.mlpackage")
