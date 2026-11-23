"""Rebuild Fluent/Resources/Models/PunctCapSeg.mlpackage.

Converts the multilingual punctuation / true-casing / sentence-boundary model
1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase (Apache-2.0, 47 languages
including Arabic) from ONNX to Core ML, so the app no longer needs ONNX Runtime.

Pipeline: ONNX -> PyTorch (onnx2torch) -> TorchScript trace -> Core ML.
Output: fixed input shape [1, 256] int32 (pad with id 1), FP32 compute,
int8 weights (~270 MB). FP16 compute is NOT used: it flips the cap/seg heads.

Usage (Python 3.12):
    uv venv --python 3.12 .venv
    uv pip install --python .venv/bin/python "torch==2.7.0" "torchvision==0.22.0" \
        onnx onnx2torch coremltools onnxruntime sentencepiece numpy huggingface_hub
    .venv/bin/python -I scripts/convert_punctuation_model.py Fluent/Resources/Models
"""

import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
import torch
from coremltools.converters.mil.frontend.torch.torch_op_registry import _TORCH_OPS_REGISTRY
from huggingface_hub import hf_hub_download
from onnx2torch import convert
from sentencepiece import SentencePieceProcessor

REPO = "1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase"
REVISION = "d1769a597ce8dfaa070d436bc67d4ee761f58884"
MAX_LEN = 256
PAD_ID = 1
OUTPUTS = ["pre_preds", "post_preds", "cap_preds", "seg_preds"]

# onnx2torch emits aten ops that coremltools only knows under their short names.
for alias, target in [("greater", "gt"), ("less", "lt"), ("greater_equal", "ge"), ("less_equal", "le")]:
    mapping = _TORCH_OPS_REGISTRY.name_to_func_mapping
    if alias not in mapping and target in mapping:
        mapping[alias] = mapping[target]


class Wrapper(torch.nn.Module):
    """int32 in / int32 out, since Core ML has no int64 inputs or bool outputs."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, ids):
        pre, post, cap, seg = self.model(ids.long())
        return pre.int(), post.int(), cap.int(), seg.int()


def main(out_dir: Path):
    onnx_path = hf_hub_download(REPO, "model.onnx", revision=REVISION)
    sp_path = hf_hub_download(REPO, "sp.model", revision=REVISION)

    torch_model = convert(onnx.load(onnx_path)).eval()
    # onnx2torch reads the missing CumSum attributes as reverse=True, which breaks
    # the position ids. The graph's CumSum has no attributes, i.e. a plain forward sum.
    for _, module in torch_model.named_modules():
        if type(module).__name__ == "OnnxCumSum":
            module.exclusive = False
            module.reverse = False

    wrapper = Wrapper(torch_model).eval()
    example = torch.randint(5, 1000, (1, MAX_LEN), dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, check_trace=False)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=(1, MAX_LEN), dtype=np.int32)],
        outputs=[ct.TensorType(name=name) for name in OUTPUTS],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram",
    )
    mlmodel = ct.optimize.coreml.linear_quantize_weights(
        mlmodel,
        config=ct.optimize.coreml.OptimizationConfig(
            global_config=ct.optimize.coreml.OpLinearQuantizerConfig(
                mode="linear_symmetric", dtype="int8", weight_threshold=2048
            )
        ),
    )

    # Verify against the original ONNX graph before saving.
    tokenizer = SentencePieceProcessor(sp_path)
    reference = ort.InferenceSession(onnx_path)
    samples = [
        "مرحبا يا أحمد كيف حالك اليوم أتمنى أن تكون بخير هل الاجتماع غدا",
        "hey how are you doing i wanted to ask about the meeting tomorrow",
    ]
    for text in samples:
        ids = [tokenizer.bos_id()] + tokenizer.EncodeAsIds(text) + [tokenizer.eos_id()]
        n = len(ids)
        padded = np.array([ids + [PAD_ID] * (MAX_LEN - n)], dtype=np.int32)
        got = mlmodel.predict({"input_ids": padded})
        want = reference.run(None, {"input_ids": np.array([ids], dtype=np.int64)})
        for name, expected in zip(OUTPUTS, want):
            agreement = (np.asarray(got[name])[0, :n] == np.asarray(expected)[0, :n]).mean()
            print(f"{name}: {agreement:.3f} agreement")
            if agreement < 0.98:
                raise SystemExit(f"Core ML output diverges from ONNX on {name}")

    out_dir.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out_dir / "PunctCapSeg.mlpackage"))
    Path(out_dir / "xlmr_punct_sp.model").write_bytes(Path(sp_path).read_bytes())
    print("Saved to", out_dir)


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "Fluent/Resources/Models"))
