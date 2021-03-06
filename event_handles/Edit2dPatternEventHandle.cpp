#include <QEvent>
#include <GL\glew.h>
#include "Viewer2d.h"
#include "viewer3d.h"
#include "cloth\clothManager.h"
#include "cloth\clothPiece.h"
#include "cloth\graph\Graph.h"
#include "cloth\HistoryStack.h"
#include "Renderable\ObjMesh.h"
#include "..\clothdesigner.h"
#include "Edit2dPatternEventHandle.h"
Edit2dPatternEventHandle::Edit2dPatternEventHandle(Viewer2d* v)
: Abstract2dEventHandle(v)
{
	QString name = "icons/pattern_edit.png";
	QPixmap img(name);
	img = img.scaledToWidth(32, Qt::TransformationMode::SmoothTransformation);
	m_cursor = QCursor(img, 1, 1);
	m_iconFile = name;
	m_inactiveIconFile = name;
	m_toolTips = "edit pattern";
}

Edit2dPatternEventHandle::~Edit2dPatternEventHandle()
{

}

void Edit2dPatternEventHandle::handleEnter()
{
	Abstract2dEventHandle::handleEnter();
	m_viewer->setFocus();
}
void Edit2dPatternEventHandle::handleLeave()
{
	m_viewer->clearFocus();
	m_viewer->endDragBox();
	Abstract2dEventHandle::handleLeave();
}

void Edit2dPatternEventHandle::mousePressEvent(QMouseEvent *ev)
{
	Abstract2dEventHandle::mousePressEvent(ev);

	if (ev->buttons() == Qt::LeftButton)
	{
		pick(ev->pos());
		if (pickInfo().renderId == 0)
			m_viewer->beginDragBox(ev->pos());
	} // end if left button
}

void Edit2dPatternEventHandle::mouseReleaseEvent(QMouseEvent *ev)
{
	auto manager = m_viewer->getManager();
	if (manager == nullptr)
		return;

	if (m_viewer->buttons() & Qt::LeftButton)
	{
		auto op = ldp::AbstractGraphObject::SelectThis;
		if (ev->modifiers() & Qt::SHIFT)
			op = ldp::AbstractGraphObject::SelectUnion;
		if (ev->modifiers() & Qt::CTRL)
			op = ldp::AbstractGraphObject::SelectUnionInverse;
		if (ev->pos() == m_mouse_press_pt)
		{
			bool changed = false;
			for (size_t iPiece = 0; iPiece < manager->numClothPieces(); iPiece++)
			{
				auto piece = manager->clothPiece(iPiece);
				auto& panel = piece->graphPanel();
				if (panel.select(pickInfo().renderId, op))
					changed = true;
			} // end for iPiece
			if (m_viewer->getMainUI() && changed)
			{
				m_viewer->getMainUI()->viewer3d()->updateGL();
				m_viewer->getMainUI()->updateUiByParam();
				m_viewer->getMainUI()->pushHistory(QString().sprintf("pattern select: %d",
				pickInfo().renderId), ldp::HistoryStack::TypePatternSelect);
			}
		} // end if single selection
		else
		{
			const QImage& I = m_viewer->fboImage();
			std::set<int> ids;
			float x0 = std::max(0, std::min(m_mouse_press_pt.x(), ev->pos().x()));
			float x1 = std::min(I.width() - 1, std::max(m_mouse_press_pt.x(), ev->pos().x()));
			float y0 = std::max(0, std::min(m_mouse_press_pt.y(), ev->pos().y()));
			float y1 = std::min(I.height() - 1, std::max(m_mouse_press_pt.y(), ev->pos().y()));
			for (int y = y0; y <= y1; y++)
			for (int x = x0; x <= x1; x++)
				ids.insert(m_viewer->fboRenderedIndex(QPoint(x, y)));
			bool changed = false;
			for (size_t iPiece = 0; iPiece < manager->numClothPieces(); iPiece++)
			{
				auto piece = manager->clothPiece(iPiece);
				auto& panel = piece->graphPanel();
				if (panel.select(ids, op))
					changed = true;
			} // end for iPiece
			if (m_viewer->getMainUI() && changed)
			{
				m_viewer->getMainUI()->viewer3d()->updateGL();
				m_viewer->getMainUI()->updateUiByParam();
				m_viewer->getMainUI()->pushHistory(QString().sprintf("pattern select: %d...",
					*ids.begin()), ldp::HistoryStack::TypePatternSelect);
			}
		} // end else group selection
	}
	m_viewer->endDragBox();
	Abstract2dEventHandle::mouseReleaseEvent(ev);
}

void Edit2dPatternEventHandle::mouseDoubleClickEvent(QMouseEvent *ev)
{
	Abstract2dEventHandle::mouseDoubleClickEvent(ev);
}

void Edit2dPatternEventHandle::mouseMoveEvent(QMouseEvent *ev)
{
	Abstract2dEventHandle::mouseMoveEvent(ev);
}

void Edit2dPatternEventHandle::wheelEvent(QWheelEvent *ev)
{
	Abstract2dEventHandle::wheelEvent(ev);
}

void Edit2dPatternEventHandle::keyPressEvent(QKeyEvent *ev)
{
	Abstract2dEventHandle::keyPressEvent(ev);
	auto manager = m_viewer->getManager();
	if (!manager)
		return;
	ldp::AbstractGraphObject::SelectOp op = ldp::AbstractGraphObject::SelectEnd;
	bool changed = false;
	bool shouldTriangulate = false;
	QString str;
	switch (ev->key())
	{
	default:
		break;
	case Qt::Key_A:
		if (ev->modifiers() == Qt::CTRL)
			op = ldp::AbstractGraphObject::SelectAll;
		break;
	case Qt::Key_D:
		if (ev->modifiers() == Qt::CTRL)
			op = ldp::AbstractGraphObject::SelectNone;
		break;
	case Qt::Key_I:
		if (ev->modifiers() == (Qt::CTRL | Qt::SHIFT))
			op = ldp::AbstractGraphObject::SelectInverse;
		break;
	case Qt::Key_Delete:
		if (ev->modifiers() == Qt::NoModifier)
		{
			if (manager->removeSelectedShapes())
			{
				changed = true;
				shouldTriangulate = true;
				str = "pattern removed";
			}
		}
		break;
	case Qt::Key_L:
		if (ev->modifiers() == Qt::NoModifier)
		{
			if (manager->makeSelectedCurvesToLoop())
			{
				changed = true;
				shouldTriangulate = true;
				str = "curves to loop";
			}
		}
		if (ev->modifiers() == Qt::SHIFT)
		{
			if (manager->removeLoopsOfSelectedCurves())
			{
				changed = true;
				shouldTriangulate = true;
				str = "remove loop";
			}
		}
		break;
	case Qt::Key_M:
		if (ev->modifiers() == Qt::NoModifier)
		{
			bool change = manager->mergeSelectedCurves();
			if (change)
				str = "merge curves";
			if (!change)
			{
				change = manager->mergeTheSelectedKeyPointToCurve();
				if (change)
					str = "merge point to curve";
			}
			if (!change)
			{
				change = manager->mergeSelectedKeyPoints();
				if (change)
					str = "merge key points";
			}
			if (change)
			{
				changed = true;
				shouldTriangulate = true;
			}
		}
		break;
	case Qt::Key_S:
		if (ev->modifiers() == Qt::NoModifier)
		{
			ldp::Float3 lp3(m_viewer->lastMousePos().x(), m_viewer->height() - 1 - m_viewer->lastMousePos().y(), 1);
			lp3 = m_viewer->camera().getWorldCoords(lp3);
			if (manager->splitSelectedCurve(ldp::Float2(lp3[0], lp3[1])))
			{
				changed = true;
				shouldTriangulate = true;
				str = "split curve";
			}
		}
		break;
	}

	for (size_t iPiece = 0; iPiece < manager->numClothPieces(); iPiece++)
	{
		auto piece = manager->clothPiece(iPiece);
		auto& panel = piece->graphPanel();
		if (panel.select(0, op))
		{
			changed = true;
			str = QString().sprintf("pattern select: all(%d)", op);
		}
	} // end for iPiece

	if (m_viewer->getMainUI() && changed)
	{
		if (shouldTriangulate)
			manager->triangulate();
		m_viewer->getMainUI()->viewer3d()->updateGL();
		m_viewer->getMainUI()->updateUiByParam();
		m_viewer->getMainUI()->pushHistory(str, ldp::HistoryStack::TypeGeneral);
	}
}

void Edit2dPatternEventHandle::keyReleaseEvent(QKeyEvent *ev)
{
	Abstract2dEventHandle::keyReleaseEvent(ev);
}
