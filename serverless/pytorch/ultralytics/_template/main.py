import base64
import io
import json

import yaml
from PIL import Image
from ultralytics import YOLO


def init_context(context):
    context.logger.info("Init context...  0%")

    with open("/opt/nuclio/function.yaml", "rb") as f:
        functionconfig = yaml.safe_load(f)
    labels_spec = functionconfig["metadata"]["annotations"]["spec"]
    labels = {item["id"]: item["name"] for item in json.loads(labels_spec)}

    model = YOLO("/opt/nuclio/model.pt")
    context.user_data.model = model
    context.user_data.labels = labels

    context.logger.info("Init context...100%")


def handler(context, event):
    context.logger.info("Run YOLO detector")
    data = event.body
    buf = io.BytesIO(base64.b64decode(data["image"]))
    threshold = float(data.get("threshold", 0.25))
    image = Image.open(buf).convert("RGB")

    results = context.user_data.model.predict(
        source=image,
        conf=threshold,
        verbose=False,
    )[0]

    labels = context.user_data.labels
    detections = []
    for box in results.boxes:
        cls_id = int(box.cls.item())
        conf = float(box.conf.item())
        x1, y1, x2, y2 = box.xyxy[0].tolist()
        detections.append(
            {
                "confidence": str(conf),
                "label": labels.get(cls_id, str(cls_id)),
                "points": [x1, y1, x2, y2],
                "type": "rectangle",
            }
        )

    return context.Response(
        body=json.dumps(detections),
        headers={},
        content_type="application/json",
        status_code=200,
    )
